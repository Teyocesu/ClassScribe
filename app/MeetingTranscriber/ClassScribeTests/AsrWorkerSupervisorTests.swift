import Foundation
@preconcurrency import Dispatch
import Testing
@testable import ClassScribe

private struct AsrSupervisorTestContext {
    let attempt: SessionAttemptID
    let worker: FakeAsrWorker
    let clock: FakeAsrWorkerClock
    let supervisor: AsrWorkerSupervisor
}

private func makeAsrSupervisor(
    scenario: AsrFakeWorkerScenario,
    configuration: AsrWorkerSupervisorConfiguration = .init(
        handshakeDeadline: 1,
        absoluteJobDeadline: 3,
        heartbeatInterval: 0.25,
        heartbeatInactivityBudget: 0.75,
        cancellationGracePeriod: 0.5,
        automaticMonitoring: false,
    ),
    isCurrentAttempt: @escaping (SessionAttemptID) -> Bool = { _ in true },
) -> AsrSupervisorTestContext {
    let attempt = SessionAttemptID(generation: 1)
    let worker = FakeAsrWorker(scenario: scenario)
    let clock = FakeAsrWorkerClock()
    let supervisor = AsrWorkerSupervisor(
        attemptID: attempt,
        configuration: configuration,
        worker: worker,
        clock: clock,
        isCurrentAttempt: isCurrentAttempt,
    )
    return AsrSupervisorTestContext(attempt: attempt, worker: worker, clock: clock, supervisor: supervisor)
}

@Test("ASR compatible handshake, heartbeat, progress, result y cleanup")
func successfulHandshakeAndResult() {
    let context = makeAsrSupervisor(scenario: .success)
    context.supervisor.start(sourceReference: "fixture-input")

    #expect(context.supervisor.state == .succeeded)
    #expect(context.supervisor.asrPhase == .idle)
    #expect(context.supervisor.terminalResult?.reason == .success)
    #expect(context.supervisor.terminalResult?.text == "fake transcript")
    #expect(context.supervisor.latestProgress == 1)
    #expect(context.worker.isTerminated)
    #expect(context.worker.terminateCount == 1)
    #expect(context.worker.sentMessages.map(\.messageType) == [.hello, .start, .shutdown])
}

@Test("La cancelación cooperativa completa el supervisor y limpia el worker")
func cancellationTerminatesCooperativeWorker() {
    let context = makeAsrSupervisor(scenario: .delayedSuccess)
    context.supervisor.start()
    context.supervisor.cancel()

    #expect(context.supervisor.terminalResult?.reason == .cancelled)
    #expect(context.supervisor.state == .cancelled)
    #expect(context.worker.isTerminated)
    #expect(context.worker.terminateCount == 1)
}

@Test("La cancelación termina un worker que ignora el cancel")
func cancellationKillsUncooperativeWorker() {
    let context = makeAsrSupervisor(scenario: .ignoresCancellation)
    context.supervisor.start()
    context.supervisor.cancel()
    #expect(context.supervisor.state == .cancelling)

    context.supervisor.advance(by: 0.5)

    #expect(context.supervisor.terminalResult?.reason == .forcedCancellation)
    #expect(context.worker.isTerminated)
    #expect(context.worker.terminateCount == 1)
}

@Test("La pérdida de heartbeat termina un worker vivo pero colgado")
func heartbeatTimeoutTerminatesWorker() {
    let context = makeAsrSupervisor(scenario: .noHeartbeat)
    context.supervisor.start()
    context.supervisor.advance(by: 0.75)

    #expect(context.supervisor.terminalResult?.reason == .heartbeatTimeout)
    #expect(context.supervisor.state == .unavailableForSession)
    #expect(context.worker.isTerminated)
}

@Test("El deadline absoluto termina un worker que mantiene heartbeat")
func absoluteDeadlineTerminatesWorker() {
    let context = makeAsrSupervisor(scenario: .hangForever)
    context.supervisor.start()
    context.supervisor.advance(by: 0.5)
    context.worker.emitHeartbeat()
    context.supervisor.advance(by: 0.5)
    context.worker.emitHeartbeat()
    context.supervisor.advance(by: 0.5)
    context.worker.emitHeartbeat()
    context.supervisor.advance(by: 1.5)

    #expect(context.supervisor.terminalResult?.reason == .absoluteDeadline)
    #expect(context.worker.isTerminated)
}

@Test("El handshake también tiene un deadline explícito")
func handshakeDeadlineTerminatesWorker() {
    let context = makeAsrSupervisor(scenario: .noHandshake)
    context.supervisor.start()
    context.supervisor.advance(by: 10)

    #expect(context.supervisor.terminalResult?.reason == .absoluteDeadline)
    #expect(context.supervisor.terminalResult?.message == "handshake deadline")
    #expect(context.worker.isTerminated)
}

@Test("Un salto del fake clock usa diez segundos reales en una evaluación")
func fakeClockJumpUsesElapsedTime() {
    let context = makeAsrSupervisor(scenario: .noHandshake)
    context.supervisor.start()
    context.clock.advance(by: 10)
    context.supervisor.evaluateNow()

    #expect(context.supervisor.currentTime == 10)
    #expect(context.supervisor.terminalResult?.reason == .absoluteDeadline)
}

@Test("Un crash antes del handshake produce un terminal recuperable")
func crashBeforeHandshake() {
    let context = makeAsrSupervisor(scenario: .crashBeforeHandshake)
    context.supervisor.start()

    #expect(context.supervisor.terminalResult?.reason == .crashBeforeHandshake)
    #expect(context.supervisor.state == .failedRecoverable)
    #expect(context.worker.isTerminated)
}

@Test("Un crash durante el job no deja el supervisor esperando")
func crashDuringJob() {
    let context = makeAsrSupervisor(scenario: .crashDuringJob)
    context.supervisor.start()

    #expect(context.supervisor.terminalResult?.reason == .crashDuringJob)
    #expect(context.supervisor.state == .failedRecoverable)
    #expect(context.worker.isTerminated)
}

@Test("Una versión incompatible se rechaza sin fallback silencioso")
func incompatibleProtocolRejected() {
    let context = makeAsrSupervisor(scenario: .protocolVersionMismatch)
    context.supervisor.start()

    #expect(context.supervisor.terminalResult?.reason == .incompatibleProtocol)
    #expect(context.supervisor.state == .unavailableForSession)
    #expect(context.worker.sentMessages.map(\.messageType) == [.hello, .shutdown])
}

@Test("Un mensaje malformado no se interpreta como transcript")
func malformedMessageRejected() {
    let context = makeAsrSupervisor(scenario: .malformedMessage)
    context.supervisor.start()

    #expect(context.supervisor.terminalResult?.reason == .malformedProtocol)
    #expect(context.supervisor.terminalResult?.text == nil)
    #expect(context.supervisor.state == .failedRecoverable)
}

@Test("Un frame raw malformado llega al supervisor como fault tipado")
func malformedRawFrameReachesSupervisor() {
    let context = makeAsrSupervisor(scenario: .delayedSuccess)
    context.supervisor.start()
    context.worker.emitFault(.malformedFrame("raw frame"))

    #expect(context.supervisor.terminalResult?.reason == .malformedProtocol)
    #expect(context.worker.isTerminated)
    #expect(context.supervisor.terminalResult?.text == nil)
}

@Test("Un fallo de escritura no deja el waiter pendiente")
func transportFailureCompletesSupervisor() async {
    let context = makeAsrSupervisor(scenario: .delayedSuccess)
    context.supervisor.start()
    let waiter = Task { await context.supervisor.waitForTerminal() }
    context.worker.emitFault(.writeFailed("pipe closed"))

    let terminal = await waiter.value
    #expect(terminal.reason == .transportFailure)
    #expect(context.worker.isTerminated)
}

@Test("Un resultado de intento stale no muta el supervisor actual")
func staleAttemptResultRejected() {
    var currentAttempt: SessionAttemptID?
    let context = makeAsrSupervisor(
        scenario: .delayedSuccess,
        isCurrentAttempt: { currentAttempt == $0 },
    )
    currentAttempt = context.attempt
    context.supervisor.start()
    let nextAttempt = SessionAttemptID(sessionID: context.attempt.sessionID, generation: 2)
    currentAttempt = nextAttempt
    context.worker.completeSuccess(text: "late A")

    #expect(context.supervisor.terminalResult?.reason == .staleAttempt)
    #expect(context.supervisor.terminalResult?.text == nil)
    #expect(context.worker.isTerminated)
}

@Test("Un resultado del job equivocado se descarta")
func wrongJobResultRejected() {
    let context = makeAsrSupervisor(scenario: .wrongJobID)
    context.supervisor.start()

    #expect(context.supervisor.terminalResult == nil)
    #expect(context.supervisor.state == .running)
    #expect(context.supervisor.rejectedMessageCount == 1)
    #expect(!context.worker.isTerminated)
}

@Test("Un resultado con attempt incorrecto se descarta antes de mutar")
func wrongAttemptResultRejected() {
    let context = makeAsrSupervisor(scenario: .wrongAttemptID)
    context.supervisor.start()

    #expect(context.supervisor.terminalResult == nil)
    #expect(context.supervisor.state == .running)
    #expect(context.supervisor.rejectedMessageCount == 1)
    #expect(!context.worker.isTerminated)
}

@Test("Un ready sin versión seleccionada es handshake inválido")
func invalidHandshakeRejected() {
    let worker = FakeAsrWorker(scenario: .delayedSuccess)
    let attempt = SessionAttemptID(generation: 1)
    let supervisor = AsrWorkerSupervisor(attemptID: attempt, worker: worker)
    supervisor.start()
    worker.emit(AsrWorkerEnvelope(
        attemptID: attempt,
        jobID: supervisor.jobID,
        messageType: .ready,
    ))

    #expect(supervisor.terminalResult?.reason == .malformedProtocol)
    #expect(worker.isTerminated)
}

@Test("El decoder rechaza JSON malformado del transporte")
func malformedTransportFrameRejected() {
    #expect(throws: (any Error).self) {
        _ = try AsrWorkerEnvelope.decode(Data("{".utf8))
    }
}

@Test("Heartbeat timeout y result concurrentes producen un solo terminal")
func concurrentHeartbeatAndResultTerminalizeOnce() {
    let context = makeAsrSupervisor(scenario: .hangForever)
    context.supervisor.start()
    context.clock.advance(by: 1)

    let group = DispatchGroup()
    let supervisor = context.supervisor
    let worker = context.worker
    group.enter()
    DispatchQueue.global().async(execute: DispatchWorkItem {
        defer { group.leave() }
        supervisor.evaluateNow()
    })
    group.enter()
    DispatchQueue.global().async(execute: DispatchWorkItem {
        defer { group.leave() }
        worker.completeSuccess(text: "race result")
    })
    group.wait()

    #expect(context.supervisor.terminalResult != nil)
    #expect(context.worker.terminateCount == 1)
    #expect(context.supervisor.state != .running)
}

@Test("Cancel y process-exit concurrentes completan exactamente una vez")
func concurrentCancelAndExitTerminalizeOnce() {
    let context = makeAsrSupervisor(scenario: .ignoresCancellation)
    context.supervisor.start()

    let group = DispatchGroup()
    let supervisor = context.supervisor
    let worker = context.worker
    group.enter()
    DispatchQueue.global().async(execute: DispatchWorkItem {
        defer { group.leave() }
        supervisor.cancel()
    })
    group.enter()
    DispatchQueue.global().async(execute: DispatchWorkItem {
        defer { group.leave() }
        worker.emitExit(.crashed(9))
    })
    group.wait()

    #expect(context.supervisor.terminalResult != nil)
    #expect(context.worker.terminateCount == 1)
}

@Test("Cualquier número de waiters recibe el mismo terminal")
func multipleWaitersReceiveSameTerminal() async {
    let context = makeAsrSupervisor(scenario: .delayedSuccess)
    context.supervisor.start()

    let first = Task { await context.supervisor.waitForTerminal() }
    let second = Task { await context.supervisor.waitForTerminal() }
    await Task.yield()
    context.worker.completeSuccess(text: "shared result")

    let results = await (first.value, second.value)
    #expect(results.0 == results.1)
    #expect(results.0.reason == .success)
    #expect(results.0.text == "shared result")
}

@Test("Un worker colgado no bloquea el siguiente intento")
func hungWorkerDoesNotBlockNextAttempt() {
    var currentAttempt: SessionAttemptID?
    let first = makeAsrSupervisor(
        scenario: .hangForever,
        isCurrentAttempt: { currentAttempt == $0 },
    )
    currentAttempt = first.attempt
    first.supervisor.start()
    first.supervisor.advance(by: 0.5)
    first.worker.emitHeartbeat()
    first.supervisor.advance(by: 2.5)

    #expect(first.supervisor.terminalResult?.reason == .absoluteDeadline)
    #expect(first.worker.isTerminated)

    let secondAttempt = SessionAttemptID(sessionID: first.attempt.sessionID, generation: 2)
    currentAttempt = secondAttempt
    let secondWorker = FakeAsrWorker(scenario: .success)
    let secondClock = FakeAsrWorkerClock()
    let second = AsrWorkerSupervisor(
        attemptID: secondAttempt,
        configuration: first.supervisor.configuration,
        worker: secondWorker,
        clock: secondClock,
        isCurrentAttempt: { currentAttempt == $0 },
    )
    second.start()

    #expect(second.terminalResult?.reason == .success)
    #expect(secondWorker.isTerminated)
}

@Test("Un resultado tardío después de cancelar no revive el job")
func lateResultAfterCancellationIsRejected() {
    let context = makeAsrSupervisor(scenario: .lateResultAfterCancellation)
    context.supervisor.start()
    context.supervisor.cancel()

    #expect(context.supervisor.state == .cancelling)
    #expect(context.supervisor.terminalResult == nil)
    context.supervisor.advance(by: 0.5)

    #expect(context.supervisor.terminalResult?.reason == .forcedCancellation)
    #expect(context.supervisor.terminalResult?.text == nil)
}
