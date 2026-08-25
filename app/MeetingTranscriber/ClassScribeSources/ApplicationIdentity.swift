import AppKit
import AudioTapLib
import Darwin
import Foundation

/// The durable part of an application selection. A PID is deliberately not
/// part of this value: PIDs describe one process incarnation only.
enum ApplicationIdentityStrength: String, Equatable, Sendable {
    case strong
    case weak
}

struct ApplicationIdentity: Hashable, Sendable {
    let bundleIdentifier: String?
    let bundleURL: URL?
    let executableURL: URL?

    init(
        bundleIdentifier: String? = nil,
        bundleURL: URL? = nil,
        executableURL: URL? = nil,
    ) {
        self.bundleIdentifier = Self.normalized(bundleIdentifier)
        self.bundleURL = Self.canonicalURL(bundleURL)
        self.executableURL = Self.canonicalURL(executableURL)
    }

    var strength: ApplicationIdentityStrength {
        bundleIdentifier == nil ? .weak : .strong
    }

    var stableKey: String {
        if let bundleIdentifier {
            if let bundleURL {
                return "bundle-id:\(bundleIdentifier)|bundle-url:\(bundleURL.path)"
            }
            return "bundle-id:\(bundleIdentifier)"
        }
        if let bundleURL {
            return "weak-bundle-url:\(bundleURL.path)"
        }
        if let executableURL {
            return "weak-executable:\(executableURL.path)"
        }
        // This is an explicitly weak UI key. It never participates in a
        // replacement match, so a display name cannot silently reassign a
        // selection to another process.
        return "weak-unidentified"
    }

    /// Returns strong only for a bundle-identity match. URL and executable
    /// paths reinforce the match when both sides provide them; display names
    /// are intentionally ignored.
    func matchStrength(with candidate: ApplicationIdentity) -> ApplicationIdentityStrength? {
        if let bundleIdentifier {
            guard candidate.bundleIdentifier == bundleIdentifier else { return nil }
            if let bundleURL, let candidateBundleURL = candidate.bundleURL,
               bundleURL != candidateBundleURL {
                return nil
            }
            if let executableURL, let candidateExecutableURL = candidate.executableURL,
               executableURL != candidateExecutableURL {
                return nil
            }
            return .strong
        }

        guard strength == .weak else { return nil }
        if let bundleURL, bundleURL == candidate.bundleURL { return .weak }
        if let executableURL, executableURL == candidate.executableURL { return .weak }
        return nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "unknown" else { return nil }
        return trimmed
    }

    private static func canonicalURL(_ value: URL?) -> URL? {
        guard let value else { return nil }
        return value.standardizedFileURL.resolvingSymlinksInPath()
    }
}

/// One observed process incarnation. It is a diagnostic observation and is
/// never persisted as the selected application's logical identity.
struct ProcessIncarnation: Equatable, Sendable {
    let pid: pid_t
    let rootPID: pid_t
    let identity: ApplicationIdentity
    let displayName: String

    init(
        pid: pid_t,
        identity: ApplicationIdentity,
        displayName: String,
        rootPID: pid_t? = nil,
    ) {
        self.pid = pid
        self.rootPID = rootPID ?? pid
        self.identity = identity
        self.displayName = displayName
    }
}

typealias MacApplicationProcessSnapshot = ProcessIncarnation

/// The current capture candidate: one root incarnation plus the helper and
/// renderer PIDs observed under its bundle at this startup checkpoint.
struct ProcessTopology: Equatable, Sendable {
    let root: ProcessIncarnation
    let pids: [pid_t]
}

enum ApplicationResolutionState: String, Equatable, Sendable {
    case resolved
    case missing
    case ambiguous
    case unsupportedWeakIdentity
}

/// Structured reconciliation evidence. It intentionally contains process and
/// object IDs only; no window titles, account names, or audio content.
struct ApplicationResolutionResult: Equatable, Sendable {
    let state: ApplicationResolutionState
    let selectedIdentity: String
    let previousPID: pid_t?
    let resolvedPID: pid_t?
    let candidateCount: Int
    let candidatePIDs: [pid_t]
    let topologyPIDs: [pid_t]
    let translatedTargetPIDs: [pid_t]
    let candidate: MacApplicationProcessSnapshot?

    var isResolved: Bool {
        state == .resolved && resolvedPID != nil
    }

    var processTopology: ProcessTopology? {
        guard let candidate else { return nil }
        return ProcessTopology(root: candidate, pids: topologyPIDs)
    }

    func updating(topologyPIDs: [pid_t], translatedTargetPIDs: [pid_t]) -> Self {
        Self(
            state: state,
            selectedIdentity: selectedIdentity,
            previousPID: previousPID,
            resolvedPID: resolvedPID,
            candidateCount: candidateCount,
            candidatePIDs: candidatePIDs,
            topologyPIDs: topologyPIDs,
            translatedTargetPIDs: translatedTargetPIDs,
            candidate: candidate,
        )
    }
}

struct MacApplicationStartupPlan: Equatable, Sendable {
    let result: ApplicationResolutionResult

    var rootPID: pid_t? { result.resolvedPID }
    var topology: ProcessTopology? { result.processTopology }
    var topologyPIDs: [pid_t] { result.topologyPIDs }
    var translatedTargetPIDs: [pid_t] { result.translatedTargetPIDs }
}

enum MacApplicationIdentityResolver {
    static func resolve(
        selectedIdentity: ApplicationIdentity,
        previousPID: pid_t?,
        candidates: [MacApplicationProcessSnapshot],
    ) -> ApplicationResolutionResult {
        let matchingStrong = candidates.filter {
            selectedIdentity.matchStrength(with: $0.identity) == .strong
        }
        let matchingPIDs = matchingStrong.map(\.pid)

        if selectedIdentity.strength == .weak {
            // A weak identity may keep the exact observed incarnation, but it
            // can never select a replacement by name/path fallback.
            if let previousPID,
               let samePID = candidates.first(where: { $0.pid == previousPID }),
               selectedIdentity.matchStrength(with: samePID.identity) != nil {
                return resolved(
                    selectedIdentity: selectedIdentity,
                    previousPID: previousPID,
                    candidate: samePID,
                    candidateCount: candidates.count,
                    candidatePIDs: matchingPIDs,
                )
            }
            return ApplicationResolutionResult(
                state: .unsupportedWeakIdentity,
                selectedIdentity: selectedIdentity.stableKey,
                previousPID: previousPID,
                resolvedPID: nil,
                candidateCount: candidates.count,
                candidatePIDs: matchingPIDs,
                topologyPIDs: [],
                translatedTargetPIDs: [],
                candidate: nil,
            )
        }

        guard !matchingStrong.isEmpty else {
            return ApplicationResolutionResult(
                state: .missing,
                selectedIdentity: selectedIdentity.stableKey,
                previousPID: previousPID,
                resolvedPID: nil,
                candidateCount: candidates.count,
                candidatePIDs: [],
                topologyPIDs: [],
                translatedTargetPIDs: [],
                candidate: nil,
            )
        }
        guard matchingStrong.count == 1, let candidate = matchingStrong.first else {
            return ApplicationResolutionResult(
                state: .ambiguous,
                selectedIdentity: selectedIdentity.stableKey,
                previousPID: previousPID,
                resolvedPID: nil,
                candidateCount: matchingStrong.count,
                candidatePIDs: matchingPIDs,
                topologyPIDs: [],
                translatedTargetPIDs: [],
                candidate: nil,
            )
        }
        return resolved(
            selectedIdentity: selectedIdentity,
            previousPID: previousPID,
            candidate: candidate,
            candidateCount: matchingStrong.count,
            candidatePIDs: matchingPIDs,
        )
    }

    private static func resolved(
        selectedIdentity: ApplicationIdentity,
        previousPID: pid_t?,
        candidate: MacApplicationProcessSnapshot,
        candidateCount: Int,
        candidatePIDs: [pid_t],
    ) -> ApplicationResolutionResult {
        ApplicationResolutionResult(
            state: .resolved,
            selectedIdentity: selectedIdentity.stableKey,
            previousPID: previousPID,
            resolvedPID: candidate.pid,
            candidateCount: candidateCount,
            candidatePIDs: candidatePIDs,
            topologyPIDs: [candidate.pid],
            translatedTargetPIDs: [],
            candidate: candidate,
        )
    }

    static func liveCandidates(excluding ownPID: pid_t) -> [MacApplicationProcessSnapshot] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            let pid = app.processIdentifier
            guard pid > 0, pid != ownPID,
                  app.activationPolicy == .regular,
                  let name = app.localizedName,
                  !name.isEmpty else { return nil }
            return MacApplicationProcessSnapshot(
                pid: pid,
                identity: ApplicationIdentity(
                    bundleIdentifier: app.bundleIdentifier,
                    bundleURL: app.bundleURL,
                    executableURL: app.executableURL,
                ),
                displayName: name,
            )
        }
    }
}

/// Startup-only reconciliation. The loop is intended to run from a detached
/// task: process enumeration and CoreAudio registration probes never block the
/// MainActor. There is deliberately no method that rebinds a live recorder.
enum MacApplicationStartupReconciler {
    static func reconcile(
        selectedIdentity: ApplicationIdentity,
        previousPID: pid_t?,
        attempt: SessionAttemptID,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.05,
        candidates: @escaping @Sendable () -> [MacApplicationProcessSnapshot],
        topology: @escaping @Sendable (MacApplicationProcessSnapshot) -> [pid_t],
        translatedTargets: @escaping @Sendable ([pid_t]) -> [pid_t],
        isCurrentAttempt: @escaping @Sendable (SessionAttemptID) -> Bool,
        isProcessAlive: @escaping @Sendable (pid_t) -> Bool = Self.processIsRunning,
    ) async throws -> MacApplicationStartupPlan {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(max(0, timeout)))
        var latest: ApplicationResolutionResult?

        while true {
            try Task.checkCancellation()
            guard isCurrentAttempt(attempt) else { throw CancellationError() }

            let observed = candidates()
            var result = MacApplicationIdentityResolver.resolve(
                selectedIdentity: selectedIdentity,
                previousPID: previousPID,
                candidates: observed,
            )
            if let candidate = result.candidate {
                var pids = [candidate.pid] + topology(candidate)
                var seen = Set<pid_t>()
                pids = pids.filter { pid in
                    pid > 0 && pid != getpid() && isProcessAlive(pid) && seen.insert(pid).inserted
                }
                let translated = translatedTargets(pids)
                result = result.updating(
                    topologyPIDs: pids,
                    translatedTargetPIDs: translated,
                )
                latest = result
                if result.isResolved, !translated.isEmpty {
                    guard isCurrentAttempt(attempt) else { throw CancellationError() }
                    return MacApplicationStartupPlan(result: result)
                }
            } else {
                latest = result
            }

            // Ambiguity and weak replacement are explicit recoverable states;
            // waiting cannot make a silent choice safe. Missing/registration
            // gaps remain retryable until the existing startup deadline.
            if result.state == .ambiguous || result.state == .unsupportedWeakIdentity {
                guard isCurrentAttempt(attempt) else { throw CancellationError() }
                return MacApplicationStartupPlan(result: result)
            }
            guard clock.now < deadline else {
                guard isCurrentAttempt(attempt) else { throw CancellationError() }
                return MacApplicationStartupPlan(result: latest ?? result)
            }
            try await Task.sleep(for: .seconds(max(0.001, pollInterval)))
        }
    }

    private static func processIsRunning(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
