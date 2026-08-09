@testable import ClassScribe
import Darwin
import Foundation
import Testing

@Test
func supervisorDistinguishesExitFailureAndAbort() async throws {
    let folder = try makeDiarizationTestFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let success = try await DiarizationSubprocess.execute(
        executableURL: URL(fileURLWithPath: "/usr/bin/true"),
        arguments: [],
        currentDirectoryURL: folder,
    )
    #expect(success == .exit(0))

    let failure = try await DiarizationSubprocess.execute(
        executableURL: URL(fileURLWithPath: "/usr/bin/false"),
        arguments: [],
        currentDirectoryURL: folder,
    )
    #expect(failure == .exit(1))

    let abort = try await DiarizationSubprocess.execute(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "kill -ABRT $$"],
        currentDirectoryURL: folder,
    )
    #expect(abort == .signal(SIGABRT))
}

@Test
func missingAndMalformedResponsesRemainRecoverable() async throws {
    let folder = try makeDiarizationTestFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let audio = folder.appendingPathComponent("source.wav")
    try Data([0]).write(to: audio)

    do {
        _ = try await DiarizationProcessRunner(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
        ).run(audioURL: audio)
        Issue.record("Se esperaba respuesta ausente")
    } catch let error as DiarizationProcessError {
        #expect(error == .missingResponse)
    }
    #expect(try hiddenDiarizationFiles(in: folder).isEmpty)

    let malformedWorker = try makeWorkerScript(
        in: folder,
        body: "printf '{' > \"$output\"",
    )
    do {
        _ = try await DiarizationProcessRunner(executableURL: malformedWorker).run(audioURL: audio)
        Issue.record("Se esperaba respuesta malformada")
    } catch let error as DiarizationProcessError {
        #expect(error == .malformedResponse)
    }
    #expect(try hiddenDiarizationFiles(in: folder).isEmpty)
}

@Test
func isolatedWorkerReturnsValidatedContract() async throws {
    let folder = try makeDiarizationTestFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let audio = folder.appendingPathComponent("source.wav")
    try Data([0]).write(to: audio)
    let worker = try makeWorkerScript(
        in: folder,
        body: """
        printf '%s%s%s' \
          '{"schemaVersion":1,"jobID":"' \
          "$job" \
          '","spans":[{"start":0,"end":1.25,"speakerID":"S1","quality":0.9}],"embeddings":{"S1":[1,0]},"failure":null}' \
          > "$output"
        /bin/chmod 600 "$output"
        """,
    )

    let response = try await DiarizationProcessRunner(executableURL: worker).run(audioURL: audio)
    #expect(response.spans.count == 1)
    #expect(response.spans[0].speakerID == "S1")
    #expect(response.embeddings["S1"] == [1, 0])
    #expect(try hiddenDiarizationFiles(in: folder).isEmpty)
}

@Test
func cancellationTerminatesWorkerAndPreservesAudio() async throws {
    let folder = try makeDiarizationTestFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let audio = folder.appendingPathComponent("source.wav")
    let original = Data([1, 2, 3, 4])
    try original.write(to: audio)
    let worker = try makeWorkerScript(
        in: folder,
        body: """
        trap '' TERM
        exec /bin/sleep 30
        """,
    )
    let runner = DiarizationProcessRunner(executableURL: worker)
    let started = Date()
    let task = Task { try await runner.run(audioURL: audio) }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()

    do {
        _ = try await task.value
        Issue.record("Se esperaba CancellationError")
    } catch is CancellationError {
        // Expected: cancellation must not be converted into a diarization failure.
    }
    #expect(Date().timeIntervalSince(started) < 5)
    #expect(try Data(contentsOf: audio) == original)
    #expect(try hiddenDiarizationFiles(in: folder).isEmpty)
}

@Test
func timeoutTerminatesHungWorkerAndPreservesRecoveryFiles() async throws {
    let folder = try makeDiarizationTestFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let audio = folder.appendingPathComponent("source.wav")
    let original = Data([4, 3, 2, 1])
    try original.write(to: audio)
    let worker = try makeWorkerScript(
        in: folder,
        body: """
        trap '' TERM
        exec /bin/sleep 30
        """,
    )
    let runner = DiarizationProcessRunner(executableURL: worker, processingTimeout: 0.05)
    let started = Date()

    do {
        _ = try await runner.run(audioURL: audio)
        Issue.record("Se esperaba timeout del helper")
    } catch let error as DiarizationProcessError {
        #expect(error == .timedOut)
    }

    #expect(Date().timeIntervalSince(started) < 4)
    #expect(try Data(contentsOf: audio) == original)
    #expect(try hiddenDiarizationFiles(in: folder).isEmpty)
}

@Test
func runnerRejectsSymbolicAudioBeforeLaunchingWorker() async throws {
    let folder = try makeDiarizationTestFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let target = folder.appendingPathComponent("outside.wav")
    try Data([1, 2, 3]).write(to: target)
    let link = folder.appendingPathComponent("source.wav")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    do {
        _ = try await DiarizationProcessRunner(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
        ).run(audioURL: link)
        Issue.record("Se esperaba rechazo del enlace simbólico")
    } catch let error as DiarizationProcessError {
        #expect(error == .invalidAudioLocation)
    }
    #expect(try Data(contentsOf: target) == Data([1, 2, 3]))
    #expect(try hiddenDiarizationFiles(in: folder).isEmpty)
}

private func makeDiarizationTestFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("classscribe-diarization-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}

private func makeWorkerScript(in folder: URL, body: String) throws -> URL {
    let script = folder.appendingPathComponent("worker-\(UUID().uuidString).sh")
    let contents = """
    #!/bin/sh
    set -eu
    request="$1"
    output=$(/usr/bin/sed -E 's/.*"outputFilename":"([^"]+)".*/\\1/' "$request")
    job=$(/usr/bin/sed -E 's/.*"jobID":"([^"]+)".*/\\1/' "$request")
    \(body)
    """
    try contents.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    return script
}

private func hiddenDiarizationFiles(in folder: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: folder,
        includingPropertiesForKeys: nil,
        options: [],
    ).filter { $0.lastPathComponent.hasPrefix(".diarization-") }
}
