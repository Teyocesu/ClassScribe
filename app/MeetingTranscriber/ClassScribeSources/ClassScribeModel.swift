import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

enum TranscriptTab: String, CaseIterable, Identifiable {
    case professor = "Profesor"
    case everyone = "Todos los hablantes"
    case review = "Revisar"
    var id: String { rawValue }
}

@MainActor
@Observable
final class ClassScribeModel {
    var mode: CaptureMode = .online
    var subject = ""
    var technicalVocabulary = ""
    var selectedApplicationID: Int32?
    var selectedMicrophoneID: String?
    var selectedTab: TranscriptTab = .professor
    var state: ProcessingState = .ready
    var statusDetail = "Selecciona una fuente y escribe el nombre de la materia."
    var elapsed: TimeInterval = 0
    var transcriptionLatency: TimeInterval = 0
    var isTranscriptionPaused = false
    var stableLiveText = ""
    var provisionalLiveText = ""
    var allSegments: [TranscriptSegment] = []
    var speakers: [SpeakerRecord] = []
    var reviewItems: [ReviewItem] = []
    var professorSpeakerID: String?
    var professorSelectionIsAutomatic = true
    var finalReplacedLive = false
    var editedProfessorText = ""
    var editedAllText = ""
    var history: [ClassMetadata] = []
    var errorMessage: String?
    var isCalibrating = false
    var calibrationSecondsRemaining = 0

    let capture: CaptureController
    private let parakeet: ParakeetService
    private let store: SessionStore
    private let finalProcessor: FinalProcessor
    private var classFolder: URL?
    private var startedAt: Date?
    private var elapsedTimer: Timer?
    private var liveTask: Task<Void, Never>?
    private var finalTask: Task<Void, Never>?
    private var accumulator = LiveTranscriptAccumulator()
    private var technicalVocabularyURL: URL?

    init() {
        let parakeet = ParakeetService()
        self.parakeet = parakeet
        store = SessionStore()
        finalProcessor = FinalProcessor(parakeet: parakeet)
        capture = CaptureController()
        capture.refreshSources()
        history = store.history()
        selectedApplicationID = capture.applications.first?.id
        selectedMicrophoneID = capture.microphones.first?.id
    }

    var isRecording: Bool { capture.isCapturing }
    var canStart: Bool {
        !capture.isBusy && !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (mode == .online ? selectedApplication != nil : selectedMicrophone != nil)
    }
    var selectedApplication: RunningApplication? {
        capture.applications.first { $0.id == selectedApplicationID }
    }
    var selectedMicrophone: MicrophoneOption? {
        capture.microphones.first { $0.id == selectedMicrophoneID }
    }
    var selectedSourceName: String {
        mode == .online ? (selectedApplication?.name ?? "Sin aplicación") : (selectedMicrophone?.name ?? "Sin micrófono")
    }
    var professorSegments: [TranscriptSegment] {
        SpeakerAssignment.professorSegments(from: allSegments, professorID: professorSpeakerID, review: reviewItems)
    }
    var displayedText: String {
        if !finalReplacedLive {
            let separator = stableLiveText.isEmpty || provisionalLiveText.isEmpty ? "" : " "
            return stableLiveText + separator + provisionalLiveText
        }
        switch selectedTab {
        case .professor:
            return editedProfessorText.isEmpty ? TranscriptExporter.plainText(professorSegments) : editedProfessorText
        case .everyone:
            return editedAllText.isEmpty ? TranscriptExporter.plainText(allSegments) : editedAllText
        case .review:
            return reviewItems.map { "[\($0.segment.formattedTimestamp)] \($0.reason)\n\($0.segment.text)" }.joined(separator: "\n\n")
        }
    }
    var currentFolder: URL? { classFolder }

    func refreshSources() {
        capture.refreshSources()
        if selectedApplication == nil { selectedApplicationID = capture.applications.first?.id }
        if selectedMicrophone == nil { selectedMicrophoneID = capture.microphones.first?.id }
    }

    func startClass() async {
        guard canStart else { return }
        errorMessage = nil
        finalReplacedLive = false
        stableLiveText = ""
        provisionalLiveText = ""
        allSegments = []
        speakers = []
        reviewItems = []
        professorSpeakerID = nil
        professorSelectionIsAutomatic = true
        editedProfessorText = ""
        editedAllText = ""
        accumulator = LiveTranscriptAccumulator()
        let now = Date()
        do {
            let folder = try store.createFolder(subject: subject, date: now)
            classFolder = folder
            startedAt = now
            technicalVocabularyURL = try makeVocabularyFile(in: folder)
            _ = try await capture.start(
                mode: mode,
                application: selectedApplication,
                microphone: selectedMicrophone,
                folder: folder
            )
            state = .recording
            statusDetail = "El audio se guarda aunque pauses la transcripción."
            startElapsedTimer()
            startLiveTranscription()
        } catch {
            state = .failed
            errorMessage = error.localizedDescription
            statusDetail = error.localizedDescription
        }
    }

    func pauseTranscription() {
        guard isRecording, !isTranscriptionPaused else { return }
        isTranscriptionPaused = true
        state = .transcriptionPaused
        statusDetail = "La grabación continúa; solo se pausó la inferencia."
    }

    func resumeTranscription() {
        guard isRecording, isTranscriptionPaused else { return }
        isTranscriptionPaused = false
        state = .recording
        statusDetail = "Transcripción reanudada; el WAV nunca se interrumpió."
    }

    func stopClass() {
        guard isRecording else { return }
        errorMessage = nil
        state = .finalizingAudio
        liveTask?.cancel()
        liveTask = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        accumulator.confirmProvisional()
        stableLiveText = accumulator.stableText
        provisionalLiveText = ""

        do {
            let stopped = try capture.stop()
            elapsed = stopped.duration
            runFinalProcessing(audioURL: stopped.url)
        } catch {
            state = .failed
            errorMessage = error.localizedDescription
            statusDetail = "El audio se conservó, pero no se pudo validar: \(error.localizedDescription)"
            persistCurrentState()
        }
    }

    func cancelFinalProcessing() {
        finalTask?.cancel()
        finalTask = nil
        state = .cancelled
        statusDetail = "Se canceló el procesamiento; el WAV y la transcripción en vivo se conservaron."
        persistCurrentState()
    }

    func selectProfessor(_ id: String) {
        professorSpeakerID = id
        professorSelectionIsAutomatic = false
        statusDetail = "Profesor cambiado a \(id); vista filtrada regenerada."
        editedProfessorText = ""
        persistFinalOutputs()
        saveProfessorReference(for: id)
    }

    func toggleReviewAssignment(_ id: UUID) {
        guard let index = reviewItems.firstIndex(where: { $0.id == id }) else { return }
        reviewItems[index].manuallyAssignedToProfessor.toggle()
        editedProfessorText = ""
        persistFinalOutputs()
    }

    func calibrateProfessorVoice() {
        guard isRecording, !isCalibrating else { return }
        isCalibrating = true
        calibrationSecondsRemaining = 20
        statusDetail = "Calibración: procura que hable principalmente el profesor durante 20 segundos."
        Task { [weak self] in
            guard let self else { return }
            for remaining in stride(from: 20, through: 1, by: -1) {
                guard !Task.isCancelled, self.isRecording else { break }
                self.calibrationSecondsRemaining = remaining
                try? await Task.sleep(for: .seconds(1))
            }
            guard self.isRecording,
                  let window = await self.capture.liveStore.window(seconds: 20),
                  let folder = self.classFolder else {
                self.isCalibrating = false
                return
            }
            do {
                let url = folder.appendingPathComponent("professor-calibration.wav")
                try WavFile.writeFloat32(window.samples, to: url)
                let result = try await self.finalProcessor.diarize(url)
                let durations = Dictionary(grouping: result.spans, by: \.speakerID)
                    .mapValues { $0.reduce(0) { $0 + $1.end - $1.start } }
                guard let dominant = durations.max(by: { $0.value < $1.value })?.key,
                      let embedding = result.embeddings[dominant] else {
                    throw InferenceError.modelUnavailable
                }
                let reference = ProfessorVoiceReference(
                    subject: self.subject,
                    createdAt: Date(),
                    sourceSpeakerID: dominant,
                    embedding: embedding
                )
                try self.store.saveVoiceReference(reference, folder: folder)
                self.statusDetail = "Referencia local de voz calibrada. No se subió ningún dato."
            } catch {
                self.errorMessage = "No se pudo calibrar la voz: \(error.localizedDescription)"
            }
            self.isCalibrating = false
            self.calibrationSecondsRemaining = 0
        }
    }

    func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(displayedText, forType: .string)
    }

    func copyForChatGPT() {
        let date = (startedAt ?? Date()).formatted(date: .long, time: .shortened)
        let text = """
        Materia: \(subject)
        Fecha: \(date)
        Duración: \(Timecode.display(elapsed))

        Transcripción del profesor:
        \(editedProfessorText.isEmpty ? TranscriptExporter.plainText(professorSegments) : editedProfessorText)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func export(_ kind: ExportKind) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(subject.filenameSlug.isEmpty ? "Clase" : subject.filenameSlug)-profesor.\(kind.extensionName)"
        panel.allowedContentTypes = [kind.contentType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let content: String
        switch kind {
        case .txt: content = editedProfessorText.isEmpty ? TranscriptExporter.plainText(professorSegments) : editedProfessorText
        case .markdown: content = TranscriptExporter.markdown(subject: subject, date: startedAt ?? Date(), segments: professorSegments)
        case .srt: content = TranscriptExporter.srt(professorSegments)
        }
        do { try content.write(to: url, atomically: true, encoding: .utf8) }
        catch { errorMessage = error.localizedDescription }
    }

    func openCurrentFolder() {
        if let classFolder { NSWorkspace.shared.activateFileViewerSelecting([classFolder]) }
    }

    func openHistoryFolder(_ metadata: ClassMetadata) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: metadata.folderPath)])
    }

    private func startElapsedTimer() {
        elapsed = 0
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startedAt = self.startedAt else { return }
                if let failure = self.capture.takeTerminalFailure() {
                    self.failActiveCapture(failure)
                    return
                }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    private func failActiveCapture(_ message: String) {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        liveTask?.cancel()
        liveTask = nil
        state = .failed
        errorMessage = message
        statusDetail = "La captura se detuvo: \(message)"
        persistCurrentState()
    }

    private func startLiveTranscription() {
        liveTask?.cancel()
        liveTask = Task { [weak self] in
            guard let self else { return }
            var lastProcessedEnd: Int64 = 0
            let minimumSamples: Int64 = 5 * 16_000
            let hopSamples: Int64 = 88_000 // 5.5 seconds; 1.5 second overlap in a 7 second window
            while !Task.isCancelled, self.isRecording {
                try? await Task.sleep(for: .milliseconds(400))
                guard !self.isTranscriptionPaused else { continue }
                let total = await self.capture.liveStore.totalSamples()
                guard total >= minimumSamples,
                      total - lastProcessedEnd >= hopSamples,
                      let window = await self.capture.liveStore.window(seconds: 7, endingAt: total) else { continue }
                lastProcessedEnd = total
                let began = Date()
                do {
                    self.state = .loadingModel
                    self.statusDetail = "Parakeet TDT v3 procesa una ventana local de 7 segundos."
                    let text = try await self.parakeet.transcribe(samples: window.samples)
                    let pause = await self.capture.liveStore.hasRecentPause()
                    self.accumulator.accept(text, confirmedByPause: pause)
                    self.stableLiveText = self.accumulator.stableText
                    self.provisionalLiveText = self.accumulator.provisionalText
                    self.transcriptionLatency = Date().timeIntervalSince(began) + 1.5
                    self.state = .recording
                    self.statusDetail = pause
                        ? "Fragmento confirmado tras una pausa de voz."
                        : "Texto tenue = hipótesis provisional pendiente de confirmar."
                    if let folder = self.classFolder {
                        try? self.store.saveLive(stable: self.stableLiveText, provisional: self.provisionalLiveText, folder: folder)
                    }
                } catch {
                    self.state = .recording
                    self.errorMessage = "Transcripción en vivo no disponible: \(error.localizedDescription). La grabación continúa."
                    self.statusDetail = "La grabación continúa; se reintentará y habrá retranscripción final."
                }
            }
        }
    }

    private func runFinalProcessing(audioURL: URL) {
        finalTask?.cancel()
        finalTask = Task { [weak self] in
            guard let self else { return }
            do {
                self.state = .finalTranscription
                self.statusDetail = "La versión en vivo permanece visible mientras se procesa el WAV completo."
                try await self.finalProcessor.configureVocabulary(file: self.technicalVocabularyURL)
                let transcript = try await self.finalProcessor.transcribe(audioURL)
                try Task.checkCancellation()
                self.state = .diarizing
                self.statusDetail = "FluidAudio identifica voces y genera embeddings locales."
                let diarization = try await self.finalProcessor.diarize(audioURL)
                try Task.checkCancellation()
                let assignment = SpeakerAssignment.assign(transcript: transcript, diarization: diarization.spans)
                self.allSegments = assignment.segments
                self.reviewItems = assignment.review
                self.speakers = self.makeSpeakers(spans: diarization.spans, embeddings: diarization.embeddings)
                self.chooseProfessorAutomatically(embeddings: diarization.embeddings)
                self.finalReplacedLive = true
                self.state = .complete
                self.statusDetail = "La transcripción final reemplazó a la versión provisional."
                self.persistFinalOutputs()
            } catch is CancellationError {
                self.state = .cancelled
                self.statusDetail = "Procesamiento cancelado; se conservaron el audio y el texto en vivo."
                self.persistCurrentState()
            } catch {
                self.state = .failed
                self.errorMessage = error.localizedDescription
                self.statusDetail = "Falló el procesamiento final; se conservaron el audio y el texto en vivo."
                self.persistCurrentState()
            }
            self.finalTask = nil
        }
    }

    private func makeSpeakers(spans: [DiarizationSpan], embeddings: [String: [Float]]) -> [SpeakerRecord] {
        let groups = Dictionary(grouping: spans, by: \.speakerID)
        return groups.map { id, values in
            let fragments = allSegments.filter { $0.speakerID == id }.suffix(3).map(\.text)
            let weightedQuality = values.reduce(0) { $0 + $1.quality } / Double(max(1, values.count))
            return SpeakerRecord(
                id: id,
                displayName: id,
                totalSpeakingTime: values.reduce(0) { $0 + $1.end - $1.start },
                recentFragments: fragments,
                confidence: weightedQuality,
                embedding: embeddings[id]
            )
        }.sorted { $0.totalSpeakingTime > $1.totalSpeakingTime }
    }

    private func makeVocabularyFile(in folder: URL) throws -> URL? {
        let terms = technicalVocabulary.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        let url = folder.appendingPathComponent("technical-vocabulary.txt")
        try terms.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    private func chooseProfessorAutomatically(embeddings: [String: [Float]]) {
        professorSelectionIsAutomatic = true
        if let reference = store.loadVoiceReference(subject: subject) {
            let matches = embeddings.compactMap { id, embedding -> (String, Double)? in
                guard let score = SpeakerAssignment.cosineSimilarity(reference.embedding, embedding) else { return nil }
                return (id, score)
            }
            if let best = matches.max(by: { $0.1 < $1.1 }), best.1 >= 0.62 {
                professorSpeakerID = best.0
                statusDetail = "Profesor asociado con una referencia local de voz (\(Int(best.1 * 100)) %)."
                return
            }
        }
        professorSpeakerID = SpeakerAssignment.provisionalProfessor(speakers: speakers)
    }

    private func saveProfessorReference(for id: String) {
        guard let folder = classFolder,
              let embedding = speakers.first(where: { $0.id == id })?.embedding else { return }
        let reference = ProfessorVoiceReference(subject: subject, createdAt: Date(), sourceSpeakerID: id, embedding: embedding)
        try? store.saveVoiceReference(reference, folder: folder)
    }

    private func metadata(state override: ProcessingState? = nil) -> ClassMetadata? {
        guard let folder = classFolder, let startedAt else { return nil }
        return ClassMetadata(
            id: UUID(),
            subject: subject,
            startedAt: startedAt,
            duration: elapsed,
            mode: mode,
            source: selectedSourceName,
            professorSpeakerID: professorSpeakerID,
            professorSelectionIsAutomatic: professorSelectionIsAutomatic,
            speakerCount: speakers.count,
            state: override ?? state,
            folderPath: folder.path,
            technicalVocabulary: technicalVocabulary
        )
    }

    private func persistFinalOutputs() {
        guard let folder = classFolder, let metadata = metadata() else { return }
        do {
            try store.saveFinal(
                metadata: metadata,
                all: allSegments,
                professor: professorSegments,
                review: reviewItems,
                speakers: speakers,
                folder: folder
            )
            history = store.history()
        } catch { errorMessage = "No se pudo guardar una exportación: \(error.localizedDescription)" }
    }

    private func persistCurrentState() {
        guard let folder = classFolder, let metadata = metadata() else { return }
        try? store.saveFinal(metadata: metadata, all: allSegments, professor: professorSegments, review: reviewItems, speakers: speakers, folder: folder)
        try? store.saveLive(stable: stableLiveText, provisional: provisionalLiveText, folder: folder)
        history = store.history()
    }
}

enum ExportKind: String, CaseIterable, Identifiable {
    case txt = "TXT"
    case markdown = "Markdown"
    case srt = "SRT"
    var id: String { rawValue }
    var extensionName: String { self == .markdown ? "md" : rawValue.lowercased() }
    var contentType: UTType {
        switch self {
        case .txt: .plainText
        case .markdown: UTType(filenameExtension: "md") ?? .plainText
        case .srt: UTType(filenameExtension: "srt") ?? .plainText
        }
    }
}
