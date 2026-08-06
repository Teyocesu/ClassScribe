@preconcurrency import AVFoundation
import FluidAudio
import Foundation

extension OfflineDiarizerManager: @retroactive @unchecked Sendable {}

actor ParakeetService {
    private var manager: AsrManager?
    private(set) var downloadProgress = 0.0
    private struct VocabularyBooster {
        let context: CustomVocabularyContext
        let spotter: CtcKeywordSpotter
        let rescorer: VocabularyRescorer
    }
    private var vocabularyBooster: VocabularyBooster?
    private var configuredVocabularyPath: String?

    func loadIfNeeded() async throws {
        guard manager == nil else { return }
        downloadProgress = 0
        let models = try await AsrModels.downloadAndLoad(version: .v3) { [weak self] progress in
            Task { await self?.setDownloadProgress(progress.fractionCompleted) }
        }
        let asr = AsrManager(config: ASRConfig(
            parallelChunkConcurrency: 2,
            melChunkContext: false,
            dualDecodeArbitration: true
        ))
        try await asr.loadModels(models)
        manager = asr
        downloadProgress = 1
    }

    func transcribe(samples: [Float]) async throws -> String {
        try await loadIfNeeded()
        guard let manager else { throw InferenceError.modelUnavailable }
        var state = await TdtDecoderState.make(decoderLayers: manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &state, language: .spanish)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func transcribe(file: URL) async throws -> [TranscriptSegment] {
        try await loadIfNeeded()
        guard let manager else { throw InferenceError.modelUnavailable }
        var state = await TdtDecoderState.make(decoderLayers: manager.decoderLayerCount)
        let result = try await manager.transcribe(file, decoderState: &state, language: .spanish)
        var segments = Self.makeSegments(result)
        if let vocabularyBooster,
           let timings = result.tokenTimings,
           !timings.isEmpty {
            let samples = try Self.loadSamples(file)
            let spotting = try await vocabularyBooster.spotter.spotKeywordsWithLogProbs(
                audioSamples: samples,
                customVocabulary: vocabularyBooster.context
            )
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
            vocabularyBooster = nil
            configuredVocabularyPath = nil
            return
        }
        guard configuredVocabularyPath != file.path else { return }
        let (context, models) = try await CustomVocabularyContext.loadWithCtcTokens(from: file.path)
        let spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
        let rescorer = try await VocabularyRescorer.create(
            spotter: spotter,
            vocabulary: context,
            config: .default,
            ctcModelDirectory: CtcModels.defaultCacheDirectory(for: models.variant)
        )
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
    private var diarizer: OfflineDiarizerManager?

    init(parakeet: ParakeetService) {
        self.parakeet = parakeet
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
        let manager: OfflineDiarizerManager
        if let existing = diarizer {
            manager = existing
        } else {
            let created = OfflineDiarizerManager()
            try await created.prepareModels()
            diarizer = created
            manager = created
        }
        let result = try await manager.process(audioURL)
        let spans = result.segments.map {
            DiarizationSpan(
                start: Double($0.startTimeSeconds),
                end: Double($0.endTimeSeconds),
                speakerID: Self.personName($0.speakerId),
                quality: Double($0.qualityScore)
            )
        }
        var embeddings: [String: [Float]] = [:]
        for (key, value) in result.speakerDatabase ?? [:] {
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

enum InferenceError: LocalizedError {
    case modelUnavailable

    var errorDescription: String? {
        "No se pudo cargar el modelo local Parakeet. Comprueba la conexión para la primera descarga y el espacio libre."
    }
}
