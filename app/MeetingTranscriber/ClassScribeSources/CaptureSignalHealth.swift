import Foundation

/// Content/transport health of one capture attempt. This is deliberately not
/// a lifecycle phase and it never claims that an audible signal is speech.
enum CaptureSignalState: String, Codable, CaseIterable, Sendable {
    case awaitingCallbacks
    case noCallbacks
    case silent
    case audible
}

/// Budgets and the signal floor are kept together so a platform adapter does
/// not grow unrelated magic numbers. The silence floor is an energy advisory,
/// not a VAD or voice classifier.
struct CaptureSignalThresholds: Equatable, Sendable {
    let initialCallbackBudget: TimeInterval
    let stallBudget: TimeInterval
    let silenceEnergyDBFS: Double

    init(
        initialCallbackBudget: TimeInterval,
        stallBudget: TimeInterval,
        silenceEnergyDBFS: Double,
    ) {
        self.initialCallbackBudget = max(0, initialCallbackBudget)
        self.stallBudget = max(0, stallBudget)
        self.silenceEnergyDBFS = silenceEnergyDBFS.isFinite ? silenceEnergyDBFS : -120
    }

    /// Existing macOS application-capture budgets: the CATap registration
    /// gate is three seconds, while the first callback has a larger budget for
    /// route negotiation. The -43 dBFS floor is the existing live-audio
    /// silence floor used for paragraph analysis; it remains provisional until
    /// a physical calibration corpus exists.
    static let macOSApplication = Self(
        initialCallbackBudget: 30,
        stallBudget: 12,
        silenceEnergyDBFS: -43,
    )

    /// The legacy microphone route has a shorter first-callback budget. It is
    /// still evaluated by the same signal model without moving its native
    /// setup/teardown to CaptureNativeExecutor.
    static let macOSMicrophone = Self(
        initialCallbackBudget: 2.5,
        stallBudget: 12,
        silenceEnergyDBFS: -43,
    )

    static let test = Self(
        initialCallbackBudget: 5,
        stallBudget: 3,
        silenceEnergyDBFS: -40,
    )
}

/// Clock abstraction for all signal-health deadlines. Production uses
/// systemUptime; tests provide a deterministic fake without sleeping.
protocol CaptureMonotonicClock: Sendable {
    func now() -> TimeInterval
}

struct SystemCaptureMonotonicClock: CaptureMonotonicClock {
    func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

/// Per-callback evidence reduced on the adapter boundary. A zero-length
/// callback is still evidence that the transport is alive; its energy is zero.
struct CaptureSignalMeasurement: Equatable, Sendable {
    let sampleCount: Int64
    let frameCount: Int64
    let rms: Double
    let energyDBFS: Double

    init(sampleCount: Int64, frameCount: Int64, rms: Double) {
        self.sampleCount = max(0, sampleCount)
        self.frameCount = max(0, frameCount)
        let safeRMS = rms.isFinite ? max(0, rms) : 0
        self.rms = safeRMS
        self.energyDBFS = safeRMS > 0
            ? max(-120, 20 * log10(safeRMS))
            : -120
    }

    init(samples: [Float], channelCount: Int) {
        let count = Int64(samples.count)
        guard channelCount > 0, !samples.isEmpty else {
            self.init(sampleCount: count, frameCount: 0, rms: 0)
            return
        }

        var sumOfSquares = 0.0
        for sample in samples {
            let value = Double(sample)
            guard value.isFinite else { continue }
            sumOfSquares += value * value
        }
        let rms = sumOfSquares > 0
            ? sqrt(sumOfSquares / Double(samples.count))
            : 0
        self.init(
            sampleCount: count,
            frameCount: count / Int64(channelCount),
            rms: rms,
        )
    }
}

struct CaptureSignalHealthSnapshot: Equatable, Sendable {
    let attempt: SessionAttemptID
    let state: CaptureSignalState
    let startedAtMonotonic: TimeInterval
    let lastCallbackAtMonotonic: TimeInterval?
    let callbackCount: Int64
    let sampleCount: Int64
    let frameCount: Int64
    let rms: Double
    let energyDBFS: Double
    let elapsedSinceStart: TimeInterval
    let elapsedSinceLastCallback: TimeInterval?

    var hasReceivedCallbacks: Bool {
        callbackCount > 0
    }

    /// `silent` is healthy transport; only no callbacks is a capture-health
    /// failure candidate. Audible intentionally does not mean voice/speech.
    var transportIsHealthy: Bool {
        switch state {
        case .awaitingCallbacks, .noCallbacks: false
        case .silent, .audible: true
        }
    }
}

/// Lock-protected health tracker owned by exactly one active attempt. The
/// audio callback only performs a short measurement/update; it never waits on
/// an actor, MainActor, file, timer, or native resource.
final class CaptureSignalHealthTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let thresholds: CaptureSignalThresholds
    private let clock: any CaptureMonotonicClock
    private var activeAttempt: SessionAttemptID?
    private var startedAtMonotonic = 0.0
    private var lastCallbackAtMonotonic: TimeInterval?
    private var callbackCount: Int64 = 0
    private var sampleCount: Int64 = 0
    private var frameCount: Int64 = 0
    private var lastRMS = 0.0
    private var lastEnergyDBFS = -120.0

    init(
        attempt: SessionAttemptID,
        thresholds: CaptureSignalThresholds,
        clock: any CaptureMonotonicClock = SystemCaptureMonotonicClock(),
    ) {
        self.thresholds = thresholds
        self.clock = clock
        begin(attempt)
    }

    func begin(_ attempt: SessionAttemptID, at now: TimeInterval? = nil) {
        let start = now ?? clock.now()
        lock.lock()
        activeAttempt = attempt
        startedAtMonotonic = start
        lastCallbackAtMonotonic = nil
        callbackCount = 0
        sampleCount = 0
        frameCount = 0
        lastRMS = 0
        lastEnergyDBFS = -120
        lock.unlock()
    }

    func invalidate(_ attempt: SessionAttemptID) {
        lock.lock()
        if activeAttempt == attempt {
            activeAttempt = nil
        }
        lock.unlock()
    }

    /// Returns false for a stale callback. The ownership check and the update
    /// are one critical section, so A cannot update B around invalidate/begin.
    @discardableResult
    func recordCallback(
        for attempt: SessionAttemptID,
        measurement: CaptureSignalMeasurement,
        at now: TimeInterval? = nil,
    ) -> Bool {
        let callbackTime = now ?? clock.now()
        lock.lock()
        guard activeAttempt == attempt else {
            lock.unlock()
            return false
        }
        callbackCount &+= 1
        sampleCount &+= measurement.sampleCount
        frameCount &+= measurement.frameCount
        lastCallbackAtMonotonic = callbackTime
        lastRMS = measurement.rms
        lastEnergyDBFS = measurement.energyDBFS
        lock.unlock()
        return true
    }

    func snapshot(
        for expectedAttempt: SessionAttemptID? = nil,
        at now: TimeInterval? = nil,
    ) -> CaptureSignalHealthSnapshot? {
        let currentTime = now ?? clock.now()
        lock.lock()
        guard let activeAttempt,
              expectedAttempt == nil || expectedAttempt == activeAttempt
        else {
            lock.unlock()
            return nil
        }

        let elapsedSinceStart = max(0, currentTime - startedAtMonotonic)
        let elapsedSinceLastCallback = lastCallbackAtMonotonic.map {
            max(0, currentTime - $0)
        }
        let state: CaptureSignalState
        if callbackCount == 0 {
            state = elapsedSinceStart >= thresholds.initialCallbackBudget
                ? .noCallbacks
                : .awaitingCallbacks
        } else if let elapsedSinceLastCallback,
                  elapsedSinceLastCallback >= thresholds.stallBudget {
            state = .noCallbacks
        } else {
            state = lastEnergyDBFS <= thresholds.silenceEnergyDBFS ? .silent : .audible
        }

        let snapshot = CaptureSignalHealthSnapshot(
            attempt: activeAttempt,
            state: state,
            startedAtMonotonic: startedAtMonotonic,
            lastCallbackAtMonotonic: lastCallbackAtMonotonic,
            callbackCount: callbackCount,
            sampleCount: sampleCount,
            frameCount: frameCount,
            rms: lastRMS,
            energyDBFS: lastEnergyDBFS,
            elapsedSinceStart: elapsedSinceStart,
            elapsedSinceLastCallback: elapsedSinceLastCallback,
        )
        lock.unlock()
        return snapshot
    }
}
