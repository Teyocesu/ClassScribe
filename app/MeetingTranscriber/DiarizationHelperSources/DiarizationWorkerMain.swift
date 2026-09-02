import ClassScribeProcessingIPC
@preconcurrency import CoreML
import Darwin
import FluidAudio
import Foundation

private enum WorkerError: LocalizedError {
    case invalidArguments
    case invalidFilename
    case incompatibleProtocol
    case outputAlreadyExists

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "Solicitud de diarización inválida."
        case .invalidFilename:
            "La solicitud contiene un nombre de archivo inválido."
        case .incompatibleProtocol:
            "La versión del protocolo de diarización no es compatible."
        case .outputAlreadyExists:
            "El archivo temporal de respuesta ya existe."
        }
    }
}

@main
private enum ClassScribeDiarizer {
    static func main() async {
        _ = Darwin.umask(0o077)
        var decodedRequest: DiarizationWorkerRequest?
        var responseURL: URL?

        do {
            guard CommandLine.arguments.count == 2 else { throw WorkerError.invalidArguments }
            let workingDirectory = URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true,
            ).standardizedFileURL
            let requestName = try validatedBasename(CommandLine.arguments[1], prefix: ".diarization-request-")
            let requestURL = workingDirectory.appendingPathComponent(requestName, isDirectory: false)
            let request = try JSONDecoder().decode(
                DiarizationWorkerRequest.self,
                from: Data(contentsOf: requestURL),
            )
            decodedRequest = request

            guard request.schemaVersion == DiarizationIPC.schemaVersion else {
                throw WorkerError.incompatibleProtocol
            }
            let inputName = try validatedBasename(request.inputFilename)
            let outputName = try validatedBasename(request.outputFilename, prefix: ".diarization-response-")
            guard requestName == ".diarization-request-\(request.jobID.uuidString).json",
                  outputName == ".diarization-response-\(request.jobID.uuidString).json",
                  inputName != requestName,
                  inputName != outputName
            else { throw WorkerError.invalidFilename }
            let audioURL = workingDirectory.appendingPathComponent(inputName, isDirectory: false)
            let outputURL = workingDirectory.appendingPathComponent(outputName, isDirectory: false)
            responseURL = outputURL
            let audioValues = try audioURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard audioValues.isRegularFile == true, audioValues.isSymbolicLink != true else {
                throw WorkerError.invalidFilename
            }

            var result = try await diarize(audioURL: audioURL)
            if DiarizationRecoveryPolicy.needsRecovery(result.spans) {
                // FluidAudio 0.15.5 can auto-detect several clusters but still
                // assign two local speakers in one segmentation chunk to the
                // same centroid.  Probe with the upstream-recommended 0.7
                // threshold, then force the probe's *dynamic* count through
                // the library's deterministic K-Means re-clustering path.
                // A long one-speaker baseline may reach this diagnostic probe,
                // but the policy accepts it only when the auto-counted result
                // shows strong, temporally distributed evidence of more voices.
                if let probe = try? await diarize(
                    audioURL: audioURL,
                    clusteringThreshold: DiarizationRecoveryPolicy.probeClusteringThreshold,
                ), let inferredCount = DiarizationRecoveryPolicy.inferredSpeakerCount(
                    baseline: result.spans,
                    probe: probe.spans,
                ), let recovered = try? await diarize(
                    audioURL: audioURL,
                    exactSpeakerCount: inferredCount,
                ), DiarizationRecoveryPolicy.shouldUseRecovery(
                    baseline: result.spans,
                    candidate: recovered.spans,
                    inferredSpeakerCount: inferredCount,
                ) {
                    result = recovered
                }
            }

            let response = DiarizationWorkerResponse(
                jobID: request.jobID,
                spans: result.spans,
                embeddings: result.embeddings,
            )
            try writePrivateAtomically(JSONEncoder().encode(response), to: outputURL)
            Darwin.exit(EXIT_SUCCESS)
        } catch {
            if let request = decodedRequest, let responseURL {
                let failure = DiarizationWorkerResponse(
                    jobID: request.jobID,
                    spans: [],
                    embeddings: [:],
                    failure: DiarizationWorkerFailure(
                        code: String(describing: type(of: error)),
                        message: error.localizedDescription,
                    ),
                )
                if let data = try? JSONEncoder().encode(failure) {
                    try? writePrivateAtomically(data, to: responseURL)
                }
            }
            fputs("ClassScribeDiarizer no pudo completar el trabajo.\n", stderr)
            Darwin.exit(EX_SOFTWARE)
        }
    }

    private struct WorkerDiarization {
        var spans: [DiarizationWorkerSpan]
        var embeddings: [String: [Float]]
    }

    private static func diarize(
        audioURL: URL,
        clusteringThreshold: Double? = nil,
        exactSpeakerCount: Int? = nil,
    ) async throws -> WorkerDiarization {
        // The physical crash occurred in the first full FBANK batch. A
        // single-item batch avoids that native batch path; process isolation
        // remains the hard safety boundary if Core ML aborts.
        var configuration = OfflineDiarizerConfig(embeddingBatchSize: 1)
        configuration.exposeChunkEmbeddings = false
        if let clusteringThreshold {
            configuration.clustering.threshold = clusteringThreshold
        }
        if let exactSpeakerCount, exactSpeakerCount > 0 {
            configuration.clustering.numSpeakers = exactSpeakerCount
        }

        let manager = OfflineDiarizerManager(config: configuration)
        let modelConfiguration = MLModelConfiguration()
        modelConfiguration.computeUnits = .cpuOnly
        try await manager.prepareModels(configuration: modelConfiguration)
        let result = try await manager.process(audioURL)
        guard result.segments.allSatisfy({
            $0.startTimeSeconds.isFinite && $0.endTimeSeconds.isFinite && $0.qualityScore.isFinite
                && $0.startTimeSeconds >= 0 && $0.endTimeSeconds >= $0.startTimeSeconds
        }), result.speakerDatabase?.values.allSatisfy({ values in
            !values.isEmpty && values.allSatisfy(\.isFinite)
        }) ?? true else { throw WorkerError.incompatibleProtocol }

        return WorkerDiarization(
            spans: result.segments.map {
                DiarizationWorkerSpan(
                    start: Double($0.startTimeSeconds),
                    end: Double($0.endTimeSeconds),
                    speakerID: $0.speakerId,
                    quality: Double($0.qualityScore),
                )
            },
            embeddings: result.speakerDatabase ?? [:],
        )
    }

    private static func validatedBasename(_ value: String, prefix: String? = nil) throws -> String {
        guard !value.isEmpty,
              value == URL(fileURLWithPath: value).lastPathComponent,
              value != ".",
              value != "..",
              !value.contains("/"),
              !value.contains(":")
        else { throw WorkerError.invalidFilename }
        if let prefix, !value.hasPrefix(prefix) {
            throw WorkerError.invalidFilename
        }
        return value
    }

    private static func writePrivateAtomically(_ data: Data, to destination: URL) throws {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw WorkerError.outputAlreadyExists
        }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".diarization-write-\(UUID().uuidString).tmp")
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600],
        ) else { throw CocoaError(.fileWriteUnknown) }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try fileManager.moveItem(at: temporary, to: destination)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }
}
