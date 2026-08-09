@preconcurrency import AVFoundation
import FluidAudio
import Foundation

/// A cancellation-aware, shared async value. The first caller starts the
/// operation; concurrent callers await that same task and a cancelled waiter
/// leaves the shared work running for the remaining callers.
///
/// Keeping this separate from `ParakeetService` makes the actor-reentrancy
/// guarantee explicit and unit-testable without downloading Core ML models.
actor AsyncSingleFlight<Value: Sendable> {
    private enum State {
        case idle
        case loading(id: UUID, task: Task<Value, Error>)
        case ready(Value)
    }

    private var state: State = .idle

    func value(
        operation: @escaping @Sendable () async throws -> Value,
    ) async throws -> Value {
        try Task.checkCancellation()

        let flight: (id: UUID, task: Task<Value, Error>)
        switch state {
        case let .ready(value):
            return value
        case let .loading(id, task):
            flight = (id, task)
        case .idle:
            let id = UUID()
            let task = Task.detached(priority: .userInitiated) {
                try await operation()
            }
            state = .loading(id: id, task: task)
            flight = (id, task)

            // A waiter can be cancelled while the shared load continues. This
            // observer still commits success (or resets failure) so the next
            // caller never starts a duplicate load after the original ended.
            Task.detached(priority: .utility) { [weak self] in
                let result = await task.result
                await self?.finish(id: id, result: result)
            }
        }

        do {
            let value = try await CancellableTaskWait.value(of: flight.task)
            finish(id: flight.id, result: .success(value))
            // Cache the successfully loaded value even if cancellation raced
            // with completion, but do not let the cancelled caller continue.
            try Task.checkCancellation()
            return value
        } catch is CancellationError {
            // Cancellation belongs to this waiter. The observer above owns the
            // shared task's eventual state transition.
            throw CancellationError()
        } catch {
            finish(id: flight.id, result: .failure(error))
            throw error
        }
    }

    private func finish(id: UUID, result: Result<Value, Error>) {
        guard case let .loading(currentID, _) = state, currentID == id else { return }
        switch result {
        case let .success(value):
            state = .ready(value)
        case .failure:
            state = .idle
        }
    }
}

/// Serializes non-reentrant inference while allowing a cancelled caller to stop
/// waiting immediately. The cancelled operation remains the queue head until
/// Core ML actually returns, preventing a final-file transcription from
/// overlapping an older live prediction that ignored cancellation.
actor AsyncSerialExecutor {
    private var tail: Task<Void, Never>?

    func run<Value: Sendable>(
        operation: @escaping @Sendable () async throws -> Value,
    ) async throws -> Value {
        try Task.checkCancellation()
        let predecessor = tail
        let operationTask = Task.detached(priority: Task.currentPriority) {
            await predecessor?.value
            try Task.checkCancellation()
            return try await operation()
        }
        tail = Task.detached(priority: .utility) {
            _ = try? await operationTask.value
        }

        return try await withTaskCancellationHandler {
            try await CancellableTaskWait.value(of: operationTask)
        } onCancel: {
            operationTask.cancel()
        }
    }
}

/// Bridges `Task.value` so cancellation stops waiting immediately without
/// cancelling the unstructured shared task itself.
private enum CancellableTaskWait {
    static func value<Value: Sendable>(of task: Task<Value, Error>) async throws -> Value {
        let box = CancellableTaskWaitBox<Value>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                box.install(continuation)
                Task.detached(priority: .utility) {
                    box.resolve(await task.result)
                }
            }
        } onCancel: {
            box.cancel()
        }
    }
}

private final class CancellableTaskWaitBox<Value: Sendable>: @unchecked Sendable {
    private enum State {
        case pending
        case waiting(CheckedContinuation<Value, Error>)
        case resolved(Result<Value, Error>)
        case cancelled
        case finished
    }

    private let lock = NSLock()
    private var state: State = .pending

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        let outcome: Result<Value, Error>?
        lock.lock()
        switch state {
        case .pending:
            state = .waiting(continuation)
            outcome = nil
        case let .resolved(result):
            state = .finished
            outcome = result
        case .cancelled:
            state = .finished
            outcome = .failure(CancellationError())
        case .waiting, .finished:
            lock.unlock()
            preconditionFailure("Continuation installed more than once")
        }
        lock.unlock()
        if let outcome {
            continuation.resume(with: outcome)
        }
    }

    func resolve(_ result: Result<Value, Error>) {
        let continuation: CheckedContinuation<Value, Error>?
        lock.lock()
        switch state {
        case .pending:
            state = .resolved(result)
            continuation = nil
        case let .waiting(waiting):
            state = .finished
            continuation = waiting
        case .resolved, .cancelled, .finished:
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(with: result)
    }

    func cancel() {
        let continuation: CheckedContinuation<Value, Error>?
        lock.lock()
        switch state {
        case .pending, .resolved:
            state = .cancelled
            continuation = nil
        case let .waiting(waiting):
            state = .finished
            continuation = waiting
        case .cancelled, .finished:
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}

actor ParakeetService {
    private let modelLoad = AsyncSingleFlight<AsrManager>()
    private let inferenceQueue = AsyncSerialExecutor()
    private(set) var downloadProgress = 0.0
    private struct VocabularyBooster {
        let context: CustomVocabularyContext
        let spotter: CtcKeywordSpotter
        let rescorer: VocabularyRescorer
    }
    private var vocabularyBooster: VocabularyBooster?
    private var configuredVocabularyPath: String?
    private var vocabularyGeneration = 0

    func loadIfNeeded() async throws {
        _ = try await loadedManager()
    }

    private func loadedManager() async throws -> AsrManager {
        try Task.checkCancellation()
        let manager = try await modelLoad.value { [weak self] in
            await self?.setDownloadProgress(0)
            let models = try await AsrModels.downloadAndLoad(version: .v3) { [weak self] progress in
                Task { await self?.setDownloadProgress(progress.fractionCompleted) }
            }
            try Task.checkCancellation()
            let asr = AsrManager(config: ASRConfig(
                parallelChunkConcurrency: 2,
                melChunkContext: false,
                dualDecodeArbitration: true
            ))
            try await asr.loadModels(models)
            try Task.checkCancellation()
            await self?.setDownloadProgress(1)
            return asr
        }
        try Task.checkCancellation()
        return manager
    }

    func transcribe(samples: [Float]) async throws -> String {
        try Task.checkCancellation()
        let manager = try await loadedManager()
        try Task.checkCancellation()
        let result = try await inferenceQueue.run {
            var state = await TdtDecoderState.make(decoderLayers: manager.decoderLayerCount)
            try Task.checkCancellation()
            return try await manager.transcribe(samples, decoderState: &state, language: .spanish)
        }
        try Task.checkCancellation()
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func transcribe(file: URL) async throws -> [TranscriptSegment] {
        try Task.checkCancellation()
        let manager = try await loadedManager()
        try Task.checkCancellation()
        let result = try await inferenceQueue.run {
            var state = await TdtDecoderState.make(decoderLayers: manager.decoderLayerCount)
            try Task.checkCancellation()
            return try await manager.transcribe(file, decoderState: &state, language: .spanish)
        }
        try Task.checkCancellation()
        var segments = Self.makeSegments(result)
        if let vocabularyBooster,
           let timings = result.tokenTimings,
           !timings.isEmpty {
            try Task.checkCancellation()
            let samples = try Self.loadSamples(file)
            try Task.checkCancellation()
            let spotting = try await vocabularyBooster.spotter.spotKeywordsWithLogProbs(
                audioSamples: samples,
                customVocabulary: vocabularyBooster.context
            )
            try Task.checkCancellation()
            if !spotting.logProbs.isEmpty {
                let output = vocabularyBooster.rescorer.ctcTokenRescore(
                    transcript: result.text,
                    tokenTimings: timings,
                    logProbs: spotting.logProbs,
                    frameDuration: spotting.frameDuration
                )
                let accepted = output.replacements.filter(\.shouldReplace)
                if !accepted.isEmpty {
                    for index in segments.indices {
                        for replacement in accepted {
                            guard let newWord = replacement.replacementWord else { continue }
                            segments[index].text = segments[index].text.replacingOccurrences(
                                of: replacement.originalWord,
                                with: newWord,
                                options: [.caseInsensitive]
                            )
                        }
                    }
                }
            }
        }
        return segments
    }

    func configureVocabulary(file: URL?) async throws {
        guard let file else {
            vocabularyGeneration += 1
            vocabularyBooster = nil
            configuredVocabularyPath = nil
            return
        }
        guard configuredVocabularyPath != file.path || vocabularyBooster == nil else { return }
        vocabularyGeneration += 1
        let generation = vocabularyGeneration
        // Never keep a previous class's booster active while a replacement is
        // loading or after that optional enhancement fails.
        vocabularyBooster = nil
        configuredVocabularyPath = nil
        try Task.checkCancellation()
        let (context, models) = try await CustomVocabularyContext.loadWithCtcTokens(from: file.path)
        try Task.checkCancellation()
        let spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
        let rescorer = try await VocabularyRescorer.create(
            spotter: spotter,
            vocabulary: context,
            config: .default,
            ctcModelDirectory: CtcModels.defaultCacheDirectory(for: models.variant)
        )
        try Task.checkCancellation()
        guard generation == vocabularyGeneration else { throw CancellationError() }
        vocabularyBooster = VocabularyBooster(context: context, spotter: spotter, rescorer: rescorer)
        configuredVocabularyPath = file.path
    }

    private func setDownloadProgress(_ value: Double) { downloadProgress = value }

    private static func loadSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw InferenceError.modelUnavailable
        }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else { throw InferenceError.modelUnavailable }
        let count = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        return (0 ..< count).map { frame in
            var sum: Float = 0
            for channel in 0 ..< channelCount { sum += channels[channel][frame] }
            return sum / Float(max(1, channelCount))
        }
    }

    static func makeSegments(_ result: ASRResult) -> [TranscriptSegment] {
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            let clean = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? [] : [TranscriptSegment(
                start: 0,
                end: max(0.2, result.duration),
                text: clean,
                speakerID: "Persona desconocida",
                confidence: Double(result.confidence)
            )]
        }
        let words = buildWordTimings(from: timings)
        guard !words.isEmpty else { return [] }
        var output: [TranscriptSegment] = []
        var current: [WordTiming] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.word).joined(separator: " ")
                .replacingOccurrences(of: " ,", with: ",")
                .replacingOccurrences(of: " .", with: ".")
                .replacingOccurrences(of: " ?", with: "?")
                .replacingOccurrences(of: " !", with: "!")
            output.append(TranscriptSegment(
                start: first.startTime,
                end: max(last.endTime, first.startTime + 0.2),
                text: text,
                speakerID: "Persona desconocida",
                confidence: Double(result.confidence)
            ))
            current.removeAll(keepingCapacity: true)
        }

        for word in words {
            if let previous = current.last,
               word.startTime - previous.endTime > 0.9 || word.endTime - current[0].startTime > 12 {
                flush()
            }
            current.append(word)
            if word.word.last.map({ ".?!".contains($0) }) == true { flush() }
        }
        flush()
        return output
    }
}

actor FinalProcessor {
    private let parakeet: ParakeetService
    private let diarizationRunner: DiarizationProcessRunner

    init(parakeet: ParakeetService, diarizationRunner: DiarizationProcessRunner = DiarizationProcessRunner()) {
        self.parakeet = parakeet
        self.diarizationRunner = diarizationRunner
    }

    func transcribe(_ audioURL: URL) async throws -> [TranscriptSegment] {
        try Task.checkCancellation()
        return try await parakeet.transcribe(file: audioURL)
    }

    func configureVocabulary(file: URL?) async throws {
        try await parakeet.configureVocabulary(file: file)
    }

    func diarize(_ audioURL: URL) async throws -> (spans: [DiarizationSpan], embeddings: [String: [Float]]) {
        try Task.checkCancellation()
        let response = try await diarizationRunner.run(audioURL: audioURL)
        let spans = response.spans.map {
            DiarizationSpan(
                start: $0.start,
                end: $0.end,
                speakerID: Self.personName($0.speakerID),
                quality: $0.quality,
            )
        }
        var embeddings: [String: [Float]] = [:]
        for (key, value) in response.embeddings {
            embeddings[Self.personName(key)] = value
        }
        return (spans, embeddings)
    }

    static func personName(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        if let number = Int(digits) { return "Persona \(number + (raw.uppercased().hasPrefix("S") ? 0 : 1))" }
        return raw.replacingOccurrences(of: "Speaker", with: "Persona")
    }
}

protocol FinalProcessingProviding: Sendable {
    func configureVocabulary(file: URL?) async throws
    func transcribe(_ audioURL: URL) async throws -> [TranscriptSegment]
    func diarize(_ audioURL: URL) async throws -> (spans: [DiarizationSpan], embeddings: [String: [Float]])
}

extension FinalProcessor: FinalProcessingProviding {}

enum InferenceError: LocalizedError {
    case modelUnavailable

    var errorDescription: String? {
        "No se pudo preparar la transcripción local. Comprueba la conexión para la primera descarga y el espacio libre."
    }
}
