import Foundation
import Testing
@testable import ClassScribe

private func fakeProcessCommand(
    scenario: String,
    filePath: String = #filePath,
) -> (URL, [String])? {
    let script = URL(fileURLWithPath: filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/AsrFakeWorkerProcess.py")
    let pythonCandidates = [
        "/usr/bin/python3",
        "/usr/local/bin/python3",
        "/opt/homebrew/bin/python3",
    ]
    guard let python = pythonCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
        return nil
    }
    return (URL(fileURLWithPath: python), [script.path, "--scenario", scenario])
}

private func makeProcessSupervisor(
    scenario: String,
    configuration: AsrWorkerSupervisorConfiguration = .init(
        handshakeDeadline: 0.25,
        absoluteJobDeadline: 0.5,
        heartbeatInterval: 0.02,
        heartbeatInactivityBudget: 0.08,
        cancellationGracePeriod: 0.08,
        automaticMonitoring: true,
    ),
) -> (ProcessAsrWorkerTransport, AsrWorkerSupervisor)? {
    guard let (executable, arguments) = fakeProcessCommand(scenario: scenario) else { return nil }
    let worker = ProcessAsrWorkerTransport(executableURL: executable, arguments: arguments)
    let supervisor = AsrWorkerSupervisor(
        attemptID: SessionAttemptID(generation: 1),
        configuration: configuration,
        worker: worker,
    )
    return (worker, supervisor)
}

private func waitForProcessExit(_ worker: ProcessAsrWorkerTransport) async -> Bool {
    for _ in 0 ..< 200 {
        if worker.hasExited { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return worker.hasExited
}

private func waitForRunning(_ supervisor: AsrWorkerSupervisor) async -> Bool {
    for _ in 0 ..< 200 {
        if supervisor.state == .running { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return supervisor.state == .running
}

@Test("process success termina y limpia el proceso real")
func processSuccess() async {
    guard let (worker, supervisor) = makeProcessSupervisor(scenario: "success") else {
        Issue.record("python3 no está disponible para el gate process-backed")
        return
    }
    supervisor.start()
    let terminal = await supervisor.waitForTerminal()

    #expect(terminal.reason == .success)
    #expect(terminal.text == "process fake transcript")
    #expect(await waitForProcessExit(worker))
    #expect(worker.terminateCount == 1)
}

@Test("process crash before handshake no bloquea")
func processCrashBeforeHandshake() async {
    guard let (worker, supervisor) = makeProcessSupervisor(scenario: "crash-before-handshake") else {
        Issue.record("python3 no está disponible para el gate process-backed")
        return
    }
    supervisor.start()
    let terminal = await supervisor.waitForTerminal()

    #expect(terminal.reason == .crashBeforeHandshake)
    #expect(await waitForProcessExit(worker))
}

@Test("process crash durante job produce terminal recuperable")
func processCrashDuringJob() async {
    guard let (worker, supervisor) = makeProcessSupervisor(scenario: "crash-during-job") else {
        Issue.record("python3 no está disponible para el gate process-backed")
        return
    }
    supervisor.start()
    let terminal = await supervisor.waitForTerminal()

    #expect(terminal.reason == .crashDuringJob)
    #expect(await waitForProcessExit(worker))
}

@Test("raw malformed frame llega al supervisor y mata el proceso")
func processMalformedRawFrame() async {
    guard let (worker, supervisor) = makeProcessSupervisor(scenario: "malformed-raw-frame") else {
        Issue.record("python3 no está disponible para el gate process-backed")
        return
    }
    supervisor.start()
    let terminal = await supervisor.waitForTerminal()

    #expect(terminal.reason == .malformedProtocol)
    #expect(terminal.text == nil)
    #expect(await waitForProcessExit(worker))
}

@Test("EOF inesperado del canal produce transportFailure")
func processUnexpectedEOF() async {
    guard let (worker, supervisor) = makeProcessSupervisor(scenario: "unexpected-eof") else {
        Issue.record("python3 no está disponible para el gate process-backed")
        return
    }
    supervisor.start()
    let terminal = await supervisor.waitForTerminal()

    #expect(terminal.reason == .transportFailure)
    #expect(await waitForProcessExit(worker))
}

@Test("process ignores cancellation y es killed tras grace")
func processIgnoresCancellation() async {
    guard let (worker, supervisor) = makeProcessSupervisor(scenario: "ignores-cancellation") else {
        Issue.record("python3 no está disponible para el gate process-backed")
        return
    }
    supervisor.start()
    #expect(await waitForRunning(supervisor))
    supervisor.cancel()
    let terminal = await supervisor.waitForTerminal()

    #expect(terminal.reason == .forcedCancellation)
    #expect(worker.terminateCount == 1)
    #expect(await waitForProcessExit(worker))
}

@Test("process heartbeat timeout mata un proceso vivo")
func processHeartbeatTimeout() async {
    guard let (worker, supervisor) = makeProcessSupervisor(scenario: "no-heartbeat") else {
        Issue.record("python3 no está disponible para el gate process-backed")
        return
    }
    supervisor.start()
    let terminal = await supervisor.waitForTerminal()

    #expect(terminal.reason == .heartbeatTimeout)
    #expect(worker.terminateCount == 1)
    #expect(await waitForProcessExit(worker))
}

@Test("process con heartbeat vence por deadline absoluto")
func processAbsoluteDeadline() async {
    let configuration = AsrWorkerSupervisorConfiguration(
        handshakeDeadline: 0.25,
        absoluteJobDeadline: 0.16,
        heartbeatInterval: 0.02,
        heartbeatInactivityBudget: 0.08,
        cancellationGracePeriod: 0.08,
        automaticMonitoring: true,
    )
    guard let (worker, supervisor) = makeProcessSupervisor(scenario: "hang", configuration: configuration) else {
        Issue.record("python3 no está disponible para el gate process-backed")
        return
    }
    supervisor.start()
    let terminal = await supervisor.waitForTerminal()

    #expect(terminal.reason == .absoluteDeadline)
    #expect(worker.terminateCount == 1)
    #expect(await waitForProcessExit(worker))
}

@Test("launch failure completa el supervisor sin dejarlo handshaking")
func processLaunchFailureCompletesSupervisor() async {
    let worker = ProcessAsrWorkerTransport(
        executableURL: URL(fileURLWithPath: "/definitely/not/a/real/executable"),
        arguments: [],
    )
    let supervisor = AsrWorkerSupervisor(
        attemptID: SessionAttemptID(generation: 1),
        worker: worker,
    )
    supervisor.start()
    let terminal = await supervisor.waitForTerminal()

    #expect(terminal.reason == .launchFailed)
    #expect(worker.terminateCount == 1)
}

@Test("un proceso A muerto permite iniciar B")
func processHungAThenB() async {
    let configuration = AsrWorkerSupervisorConfiguration(
        handshakeDeadline: 0.25,
        absoluteJobDeadline: 0.14,
        heartbeatInterval: 0.02,
        heartbeatInactivityBudget: 0.08,
        cancellationGracePeriod: 0.08,
        automaticMonitoring: true,
    )
    guard let (workerA, supervisorA) = makeProcessSupervisor(scenario: "hang", configuration: configuration),
          let (workerB, supervisorB) = makeProcessSupervisor(scenario: "success") else {
        Issue.record("python3 no está disponible para el gate process-backed")
        return
    }
    supervisorA.start()
    let terminalA = await supervisorA.waitForTerminal()
    #expect(terminalA.reason == .absoluteDeadline)
    #expect(await waitForProcessExit(workerA))

    supervisorB.start()
    let terminalB = await supervisorB.waitForTerminal()
    #expect(terminalB.reason == .success)
    #expect(await waitForProcessExit(workerB))
}
