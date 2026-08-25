import Foundation
@preconcurrency import Dispatch

enum AsrWorkerSupervisorState: Equatable, Sendable {
    case idle
    case handshaking
    case running
    case cancelling
    case succeeded
    case cancelled
    case failedRecoverable
    case unavailableForSession

    var asrPhase: AsrPhase {
        switch self {
        case .idle, .succeeded, .cancelled:
            .idle
        case .handshaking:
            .preparingLoad
        case .running:
            .transcribing
        case .cancelling, .unavailableForSession:
            .unavailableForSession
        case .failedRecoverable:
            .failedRecoverable
        }
    }
}

enum AsrWorkerTerminalReason: Equatable, Sendable {
    case success
    case cancelled
    case forcedCancellation
    case heartbeatTimeout
    case absoluteDeadline
    case crashBeforeHandshake
    case crashDuringJob
    case incompatibleProtocol
    case malformedProtocol
    case launchFailed
    case transportFailure
    case recoverableError(String)
    case terminalError(String)
    case staleAttempt
}

struct AsrWorkerTerminalResult: Equatable, Sendable {
    let reason: AsrWorkerTerminalReason
    let attemptID: SessionAttemptID
    let jobID: UUID
    let text: String?
    let code: String?
    let message: String?

    var asrPhase: AsrPhase {
        switch reason {
        case .success, .cancelled, .forcedCancellation:
            .idle
        case .heartbeatTimeout, .absoluteDeadline, .incompatibleProtocol, .staleAttempt:
            .unavailableForSession
        case .crashBeforeHandshake, .crashDuringJob, .malformedProtocol, .launchFailed,
             .transportFailure, .recoverableError, .terminalError:
            .failedRecoverable
        }
    }
}

struct AsrWorkerSupervisorConfiguration: Equatable, Sendable {
    var handshakeDeadline: TimeInterval = 10
    var absoluteJobDeadline: TimeInterval = 30 * 60
    var heartbeatInterval: TimeInterval = 1
    var heartbeatInactivityBudget: TimeInterval = 5
    var cancellationGracePeriod: TimeInterval = 0.25
    var automaticMonitoring = true

    init(
        handshakeDeadline: TimeInterval = 10,
        absoluteJobDeadline: TimeInterval = 30 * 60,
        heartbeatInterval: TimeInterval = 1,
        heartbeatInactivityBudget: TimeInterval = 5,
        cancellationGracePeriod: TimeInterval = 0.25,
        automaticMonitoring: Bool = true,
    ) {
        self.handshakeDeadline = max(0.001, handshakeDeadline)
        self.absoluteJobDeadline = max(0.001, absoluteJobDeadline)
        self.heartbeatInterval = max(0.001, heartbeatInterval)
        self.heartbeatInactivityBudget = max(0.001, heartbeatInactivityBudget)
        self.cancellationGracePeriod = max(0.001, cancellationGracePeriod)
        self.automaticMonitoring = automaticMonitoring
    }
}

protocol AsrWorkerClock: AnyObject {
    var now: TimeInterval { get }
}

final class MonotonicAsrWorkerClock: AsrWorkerClock {
    var now: TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}

final class FakeAsrWorkerClock: AsrWorkerClock {
    private let lock = NSLock()
    private var nowStorage: TimeInterval = 0

    var now: TimeInterval {
        lock.withLock { nowStorage }
    }

    func advance(by delta: TimeInterval) {
        guard delta >= 0, delta.isFinite else { return }
        lock.withLock {
            nowStorage += delta
        }
    }
}

/// Serial state machine for one supervised worker. Transport methods are
/// invoked after leaving `stateQueue`; a blocked IPC write can therefore never
/// hold the state boundary or prevent termination.
final class AsrWorkerSupervisor {
    let attemptID: SessionAttemptID
    let jobID: UUID
    let configuration: AsrWorkerSupervisorConfiguration

    private let worker: AsrWorkerTransport
    private let isCurrentAttempt: (SessionAttemptID) -> Bool
    private let clock: AsrWorkerClock
    private let stateQueue = DispatchQueue(label: "ClassScribe.AsrWorkerSupervisor.state")
    private let watchdogQueue = DispatchQueue(label: "ClassScribe.AsrWorkerSupervisor.watchdog")

    private var stateStorage: AsrWorkerSupervisorState = .idle
    private var terminalResultStorage: AsrWorkerTerminalResult?
    private var rejectedMessageCountStorage = 0
    private var latestProgressStorage: Double?
    private var currentTimeStorage: TimeInterval = 0
    private var lastHeartbeatAt: TimeInterval = 0
    private var startedAt: TimeInterval?
    private var cancellationStartedAt: TimeInterval?
    private var sourceReference: String?
    private var waiters: [CheckedContinuation<AsrWorkerTerminalResult, Never>] = []
    private var watchdog: DispatchSourceTimer?
    private var disposed = false

    private struct Actions {
        var startMessage: AsrWorkerEnvelope?
        var messages: [AsrWorkerEnvelope] = []
        var detachCallbacks = false
        var terminate = false
        var timerToCancel: DispatchSourceTimer?
        var waiters: [CheckedContinuation<AsrWorkerTerminalResult, Never>] = []
        var terminal: AsrWorkerTerminalResult?

        init(
            startMessage: AsrWorkerEnvelope? = nil,
            messages: [AsrWorkerEnvelope] = [],
            detachCallbacks: Bool = false,
            terminate: Bool = false,
            timerToCancel: DispatchSourceTimer? = nil,
            waiters: [CheckedContinuation<AsrWorkerTerminalResult, Never>] = [],
            terminal: AsrWorkerTerminalResult? = nil,
        ) {
            self.startMessage = startMessage
            self.messages = messages
            self.detachCallbacks = detachCallbacks
            self.terminate = terminate
            self.timerToCancel = timerToCancel
            self.waiters = waiters
            self.terminal = terminal
        }
    }

    init(
        attemptID: SessionAttemptID,
        jobID: UUID = UUID(),
        configuration: AsrWorkerSupervisorConfiguration = .init(),
        worker: AsrWorkerTransport,
        clock: AsrWorkerClock = MonotonicAsrWorkerClock(),
        isCurrentAttempt: @escaping (SessionAttemptID) -> Bool = { _ in true },
    ) {
        self.attemptID = attemptID
        self.jobID = jobID
        self.configuration = configuration
        self.worker = worker
        self.clock = clock
        self.isCurrentAttempt = isCurrentAttempt
        worker.onMessage = { [weak self] message in
            self?.receive(message)
        }
        worker.onExit = { [weak self] exit in
            self?.workerExited(exit)
        }
        worker.onFault = { [weak self] fault in
            self?.transportFault(fault)
        }
    }

    var state: AsrWorkerSupervisorState {
        stateQueue.sync { stateStorage }
    }

    var asrPhase: AsrPhase {
        stateQueue.sync { stateStorage.asrPhase }
    }

    var terminalResult: AsrWorkerTerminalResult? {
        stateQueue.sync { terminalResultStorage }
    }

    var rejectedMessageCount: Int {
        stateQueue.sync { rejectedMessageCountStorage }
    }

    var latestProgress: Double? {
        stateQueue.sync { latestProgressStorage }
    }

    /// The most recent monotonic clock sample observed by the state machine.
    var currentTime: TimeInterval {
        stateQueue.sync { currentTimeStorage }
    }

    func start(sourceReference: String? = nil) {
        let actions = stateQueue.sync { () -> Actions in
            guard stateStorage == .idle, !disposed else { return Actions() }
            refreshClockLocked()
            guard isCurrentAttempt(attemptID) else {
                return finishLocked(reason: .staleAttempt)
            }
            startedAt = currentTimeStorage
            lastHeartbeatAt = currentTimeStorage
            self.sourceReference = sourceReference
            stateStorage = .handshaking
            return Actions(startMessage: .hello(attemptID: attemptID, jobID: jobID))
        }

        execute(actions)
        if actions.startMessage != nil {
            installWatchdogIfNeeded()
            evaluateNow()
        }
    }

    func cancel() {
        let actions = stateQueue.sync { () -> Actions in
            guard terminalResultStorage == nil,
                  stateStorage == .handshaking || stateStorage == .running
            else { return Actions() }
            refreshClockLocked()
            stateStorage = .cancelling
            cancellationStartedAt = currentTimeStorage
            return Actions(messages: [AsrWorkerEnvelope(
                attemptID: attemptID,
                jobID: jobID,
                messageType: .cancel,
            )])
        }
        execute(actions)
        evaluateNow()
    }

    /// Advances a fake clock only. Production monitoring always samples the
    /// monotonic clock instead of accumulating timer intervals.
    func advance(by delta: TimeInterval) {
        guard let fakeClock = clock as? FakeAsrWorkerClock else { return }
        fakeClock.advance(by: delta)
        evaluateNow()
    }

    func evaluateNow() {
        let actions = stateQueue.sync { evaluateDeadlinesLocked() }
        execute(actions)
    }

    /// The async bridge is backed by the same serial state queue as all other
    /// transitions; callers may create multiple independent waiters safely.
    func waitForTerminal() async -> AsrWorkerTerminalResult {
        if let terminalResult {
            return terminalResult
        }

        return await withCheckedContinuation { continuation in
            let immediate = stateQueue.sync { () -> AsrWorkerTerminalResult? in
                if let terminalResultStorage {
                    return terminalResultStorage
                }
                waiters.append(continuation)
                return nil
            }
            if let immediate {
                continuation.resume(returning: immediate)
            }
        }
    }

    deinit {
        let cleanup = stateQueue.sync { () -> (DispatchSourceTimer?, AsrWorkerTerminalResult?, [CheckedContinuation<AsrWorkerTerminalResult, Never>]) in
            let pending = waiters
            waiters.removeAll()
            let timer = watchdog
            watchdog = nil
            if terminalResultStorage == nil {
                let terminal = AsrWorkerTerminalResult(
                    reason: .cancelled,
                    attemptID: attemptID,
                    jobID: jobID,
                    text: nil,
                    code: nil,
                    message: "supervisor disposed",
                )
                terminalResultStorage = terminal
                stateStorage = .cancelled
            }
            return (timer, terminalResultStorage, pending)
        }
        cleanup.0?.cancel()
        worker.onMessage = nil
        worker.onExit = nil
        worker.onFault = nil
        worker.terminate()
        if let terminal = cleanup.1 {
            for waiter in cleanup.2 {
                waiter.resume(returning: terminal)
            }
        }
    }

    private func receive(_ message: AsrWorkerEnvelope) {
        let actions = stateQueue.sync { () -> Actions in
            guard terminalResultStorage == nil, !disposed else { return Actions() }
            refreshClockLocked()
            guard isCurrentAttempt(attemptID) else {
                rejectedMessageCountStorage += 1
                return finishLocked(reason: .staleAttempt)
            }
            guard message.attemptID == attemptID else {
                rejectedMessageCountStorage += 1
                return Actions()
            }
            guard message.jobID == jobID else {
                rejectedMessageCountStorage += 1
                return Actions()
            }

            do {
                try message.validateShape()
            } catch {
                return finishLocked(reason: .malformedProtocol, message: "invalid envelope")
            }

            guard message.protocolVersion == AsrWorkerProtocol.supportedVersion else {
                return finishLocked(reason: .incompatibleProtocol)
            }

            switch message.messageType {
            case .ready:
                guard stateStorage == .handshaking,
                      message.selectedVersion == AsrWorkerProtocol.supportedVersion
                else {
                    return finishLocked(reason: .incompatibleProtocol)
                }
                stateStorage = .running
                lastHeartbeatAt = currentTimeStorage
                return Actions(messages: [.start(
                    attemptID: attemptID,
                    jobID: jobID,
                    sourceReference: sourceReference,
                )])
            case .heartbeat:
                guard stateStorage == .handshaking || stateStorage == .running else { return Actions() }
                lastHeartbeatAt = currentTimeStorage
                return Actions()
            case .progress:
                guard stateStorage == .running else {
                    rejectedMessageCountStorage += 1
                    return Actions()
                }
                latestProgressStorage = message.progress
                return Actions()
            case .result:
                guard stateStorage == .running else {
                    rejectedMessageCountStorage += 1
                    return Actions()
                }
                return finishLocked(reason: .success, text: message.text)
            case .recoverableError:
                guard stateStorage == .handshaking || stateStorage == .running else { return Actions() }
                return finishLocked(
                    reason: .recoverableError(message.code ?? "workerError"),
                    code: message.code,
                    message: message.message,
                )
            case .terminalError:
                guard stateStorage == .handshaking || stateStorage == .running else { return Actions() }
                return finishLocked(
                    reason: .terminalError(message.code ?? "workerError"),
                    code: message.code,
                    message: message.message,
                )
            case .cancelled:
                guard stateStorage == .cancelling else {
                    rejectedMessageCountStorage += 1
                    return Actions()
                }
                return finishLocked(reason: .cancelled)
            case .hello, .start, .cancel, .shutdown:
                return finishLocked(reason: .malformedProtocol, message: "unexpected worker message")
            }
        }
        execute(actions)
    }

    private func workerExited(_ exit: AsrWorkerExit) {
        let actions = stateQueue.sync { () -> Actions in
            guard terminalResultStorage == nil, !disposed else { return Actions() }
            refreshClockLocked()
            if stateStorage == .cancelling {
                return finishLocked(reason: .cancelled, message: "worker exit \(exit.description)")
            }
            if stateStorage == .handshaking {
                return finishLocked(reason: .crashBeforeHandshake, message: exit.description)
            }
            return finishLocked(reason: .crashDuringJob, message: exit.description)
        }
        execute(actions)
    }

    private func transportFault(_ fault: AsrWorkerTransportFault) {
        let actions = stateQueue.sync { () -> Actions in
            guard terminalResultStorage == nil, !disposed else { return Actions() }
            refreshClockLocked()
            switch fault {
            case .malformedFrame, .oversizedFrame:
                return finishLocked(reason: .malformedProtocol, message: fault.message)
            case .launchFailed:
                return finishLocked(reason: .launchFailed, message: fault.message)
            case .unexpectedEOF, .readFailed, .writeFailed:
                return finishLocked(reason: .transportFailure, message: fault.message)
            }
        }
        execute(actions)
    }

    private func evaluateDeadlinesLocked() -> Actions {
        guard terminalResultStorage == nil, !disposed else { return Actions() }
        refreshClockLocked()
        guard isCurrentAttempt(attemptID) else {
            return finishLocked(reason: .staleAttempt)
        }

        switch stateStorage {
        case .handshaking:
            if let startedAt,
               currentTimeStorage - startedAt >= configuration.handshakeDeadline
            {
                return finishLocked(reason: .absoluteDeadline, message: "handshake deadline")
            }
        case .running:
            if let startedAt,
               currentTimeStorage - startedAt >= configuration.absoluteJobDeadline
            {
                return finishLocked(reason: .absoluteDeadline, message: "job deadline")
            }
            if currentTimeStorage - lastHeartbeatAt >= configuration.heartbeatInactivityBudget {
                return finishLocked(reason: .heartbeatTimeout, message: "heartbeat timeout")
            }
        case .cancelling:
            if let cancellationStartedAt,
               currentTimeStorage - cancellationStartedAt >= configuration.cancellationGracePeriod
            {
                return finishLocked(reason: .forcedCancellation, message: "cancellation grace period")
            }
        case .idle, .succeeded, .cancelled, .failedRecoverable, .unavailableForSession:
            break
        }
        return Actions()
    }

    private func refreshClockLocked() {
        currentTimeStorage = clock.now
    }

    private func finishLocked(
        reason: AsrWorkerTerminalReason,
        text: String? = nil,
        code: String? = nil,
        message: String? = nil,
    ) -> Actions {
        guard terminalResultStorage == nil else { return Actions() }
        let terminal = AsrWorkerTerminalResult(
            reason: reason,
            attemptID: attemptID,
            jobID: jobID,
            text: text,
            code: code,
            message: message,
        )
        terminalResultStorage = terminal
        switch reason {
        case .success:
            stateStorage = .succeeded
        case .cancelled, .forcedCancellation, .staleAttempt:
            stateStorage = .cancelled
        case .heartbeatTimeout, .absoluteDeadline, .incompatibleProtocol:
            stateStorage = .unavailableForSession
        case .crashBeforeHandshake, .crashDuringJob, .malformedProtocol, .launchFailed,
             .transportFailure, .recoverableError, .terminalError:
            stateStorage = .failedRecoverable
        }
        let timer = watchdog
        watchdog = nil
        let pendingWaiters = waiters
        waiters.removeAll()
        let graceful = reason == .success || reason == .cancelled
        return Actions(
            messages: graceful ? [AsrWorkerEnvelope(
                attemptID: attemptID,
                jobID: jobID,
                messageType: .shutdown,
            )] : [],
            detachCallbacks: true,
            terminate: true,
            timerToCancel: timer,
            waiters: pendingWaiters,
            terminal: terminal,
        )
    }

    private func installWatchdogIfNeeded() {
        guard configuration.automaticMonitoring else { return }
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(
            deadline: .now() + configuration.heartbeatInterval,
            repeating: configuration.heartbeatInterval,
        )
        timer.setEventHandler(
            handler: DispatchWorkItem { [weak self] in
                self?.evaluateNow()
            },
        )

        let shouldRun = stateQueue.sync { () -> Bool in
            guard terminalResultStorage == nil, !disposed, watchdog == nil else { return false }
            watchdog = timer
            return true
        }
        if shouldRun {
            timer.resume()
        } else {
            timer.cancel()
        }
    }

    private func execute(_ actions: Actions) {
        actions.timerToCancel?.cancel()
        if actions.detachCallbacks {
            worker.onMessage = nil
            worker.onExit = nil
            worker.onFault = nil
        }
        if let startMessage = actions.startMessage {
            worker.start(with: startMessage)
        }
        for message in actions.messages {
            worker.send(message)
        }
        if actions.terminate {
            worker.terminate()
        }
        if let terminal = actions.terminal {
            for waiter in actions.waiters {
                waiter.resume(returning: terminal)
            }
        }
    }
}

enum AsrFakeWorkerScenario: CaseIterable, Sendable {
    case success
    case delayedSuccess
    case noHeartbeat
    case hangForever
    case noHandshake
    case crashBeforeHandshake
    case crashDuringJob
    case protocolVersionMismatch
    case malformedMessage
    case ignoresCancellation
    case lateResultAfterCancellation
    case wrongAttemptID
    case wrongJobID
}

final class FakeAsrWorker: AsrWorkerTransport {
    let scenario: AsrFakeWorkerScenario
    private let lock = NSLock()
    private var sentMessagesStorage: [AsrWorkerEnvelope] = []
    private var terminatedStorage = false
    private var terminateCountStorage = 0
    private var attemptID: SessionAttemptID?
    private var jobID: UUID?
    private var messageHandler: ((AsrWorkerEnvelope) -> Void)?
    private var exitHandler: ((AsrWorkerExit) -> Void)?
    private var faultHandler: ((AsrWorkerTransportFault) -> Void)?

    var sentMessages: [AsrWorkerEnvelope] { lock.withLock { sentMessagesStorage } }
    var isTerminated: Bool { lock.withLock { terminatedStorage } }
    var terminateCount: Int { lock.withLock { terminateCountStorage } }

    var onMessage: ((AsrWorkerEnvelope) -> Void)? {
        get { lock.withLock { messageHandler } }
        set { lock.withLock { messageHandler = newValue } }
    }

    var onExit: ((AsrWorkerExit) -> Void)? {
        get { lock.withLock { exitHandler } }
        set { lock.withLock { exitHandler = newValue } }
    }

    var onFault: ((AsrWorkerTransportFault) -> Void)? {
        get { lock.withLock { faultHandler } }
        set { lock.withLock { faultHandler = newValue } }
    }

    init(scenario: AsrFakeWorkerScenario) {
        self.scenario = scenario
    }

    func start(with hello: AsrWorkerEnvelope) {
        let shouldStart = lock.withLock { () -> Bool in
            guard !terminatedStorage else { return false }
            sentMessagesStorage.append(hello)
            attemptID = hello.attemptID
            jobID = hello.jobID
            return true
        }
        guard shouldStart else { return }
        switch scenario {
        case .crashBeforeHandshake:
            emitExit(.crashed(1))
        case .protocolVersionMismatch:
            emit(.ready(
                attemptID: hello.attemptID,
                jobID: hello.jobID,
                protocolVersion: AsrWorkerProtocol.supportedVersion + 1,
                selectedVersion: AsrWorkerProtocol.supportedVersion + 1,
            ))
        case .noHandshake:
            break
        default:
            emit(.ready(attemptID: hello.attemptID, jobID: hello.jobID))
        }
    }

    func send(_ message: AsrWorkerEnvelope) {
        let identity = lock.withLock { () -> (SessionAttemptID, UUID)? in
            guard !terminatedStorage, let attemptID, let jobID else { return nil }
            sentMessagesStorage.append(message)
            return (attemptID, jobID)
        }
        guard let (attemptID, jobID) = identity else { return }
        switch message.messageType {
        case .start:
            switch scenario {
            case .success:
                completeSuccess()
            case .delayedSuccess:
                emit(.heartbeat(attemptID: attemptID, jobID: jobID))
                emit(.progress(attemptID: attemptID, jobID: jobID, fraction: 0.25))
            case .noHeartbeat, .noHandshake:
                break
            case .hangForever:
                emit(.heartbeat(attemptID: attemptID, jobID: jobID))
            case .crashDuringJob:
                emitExit(.crashed(2))
            case .malformedMessage:
                emit(.result(attemptID: attemptID, jobID: jobID, text: nil))
            case .wrongAttemptID:
                let wrongAttempt = SessionAttemptID(
                    sessionID: attemptID.sessionID,
                    generation: attemptID.generation + 1,
                )
                emit(.result(attemptID: wrongAttempt, jobID: jobID, text: "late A"))
            case .wrongJobID:
                emit(.result(attemptID: attemptID, jobID: UUID(), text: "wrong job"))
            case .ignoresCancellation, .lateResultAfterCancellation, .crashBeforeHandshake, .protocolVersionMismatch:
                break
            }
        case .cancel:
            switch scenario {
            case .ignoresCancellation:
                break
            case .lateResultAfterCancellation:
                emit(.result(attemptID: attemptID, jobID: jobID, text: "late result"))
            default:
                emit(AsrWorkerEnvelope(
                    attemptID: attemptID,
                    jobID: jobID,
                    messageType: .cancelled,
                ))
            }
        case .shutdown, .hello, .ready, .heartbeat, .progress, .result, .recoverableError, .terminalError, .cancelled:
            break
        }
    }

    func terminate() {
        lock.withLock {
            guard !terminatedStorage else { return }
            terminateCountStorage += 1
            terminatedStorage = true
        }
    }

    func emitHeartbeat() {
        guard let (attemptID, jobID) = lock.withLock({ () -> (SessionAttemptID, UUID)? in
            guard let attemptID, let jobID else { return nil }
            return (attemptID, jobID)
        }) else { return }
        emit(.heartbeat(attemptID: attemptID, jobID: jobID))
    }

    func completeSuccess(text: String = "fake transcript") {
        guard let (attemptID, jobID) = lock.withLock({ () -> (SessionAttemptID, UUID)? in
            guard let attemptID, let jobID else { return nil }
            return (attemptID, jobID)
        }) else { return }
        emit(.heartbeat(attemptID: attemptID, jobID: jobID))
        emit(.progress(attemptID: attemptID, jobID: jobID, fraction: 1))
        emit(.result(attemptID: attemptID, jobID: jobID, text: text))
    }

    func emit(_ message: AsrWorkerEnvelope) {
        let handler = lock.withLock { terminatedStorage ? nil : messageHandler }
        handler?(message)
    }

    func emitFault(_ fault: AsrWorkerTransportFault) {
        let handler = lock.withLock { terminatedStorage ? nil : faultHandler }
        handler?(fault)
    }

    func emitExit(_ exit: AsrWorkerExit) {
        let handler = lock.withLock { terminatedStorage ? nil : exitHandler }
        handler?(exit)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private extension AsrWorkerExit {
    var description: String {
        switch self {
        case let .clean(status): "worker exit \(status)"
        case let .crashed(status): "worker crash \(status)"
        }
    }
}
