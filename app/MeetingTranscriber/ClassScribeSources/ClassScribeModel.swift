import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

enum TranscriptTab: String, CaseIterable, Identifiable {
    case liveEdit = "Mi edición"
    case professor = "Profesor"
    case everyone = "Todos los hablantes"
    case review = "Revisar"
    var id: String {
        rawValue
    }
}

private struct ClassSessionContext: Sendable {
    var id: UUID
    var folder: URL
    var subject: String
    var startedAt: Date
    var mode: CaptureMode
    var source: String
    var language: TranscriptionLanguage
    var technicalVocabulary: String
    var technicalVocabularyURL: URL?
}

struct RetryAudioPreparation: Sendable, Equatable {
    var duration: TimeInterval
    var recoveredRaw: Bool
}

typealias RetryAudioPreparer = @Sendable (URL, URL) async throws -> RetryAudioPreparation

private func prepareRetryAudio(audioURL: URL, rawURL: URL) async throws -> RetryAudioPreparation {
    try await Task.detached(priority: .userInitiated) {
        do {
            return try RetryAudioPreparation(duration: WavFile.validate(audioURL), recoveredRaw: false)
        } catch let wavError {
            guard FileManager.default.fileExists(atPath: rawURL.path) else { throw wavError }
            return try RetryAudioPreparation(
                duration: WavFile.recoverFloat32Raw(rawURL, destination: audioURL),
                recoveredRaw: true,
            )
        }
    }.value
}

@MainActor
@Observable
final class ClassScribeModel {
    var mode: CaptureMode = .online
    var language: TranscriptionLanguage = .spanish
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
    var editedLiveText: String?
    var editedProfessorText: String?
    var editedAllText: String?
    var history: [SessionSummary] = []
    var errorMessage: String?
    var isCalibrating = false
    var calibrationSecondsRemaining = 0
    private(set) var isStopping = false
    private(set) var isRetrying = false

    let capture: CaptureController
    private let parakeet: ParakeetService
    private let store: SessionStore
    private let finalProcessor: any FinalProcessingProviding
    private let retryAudioPreparer: RetryAudioPreparer
    private let liveTaskStopGrace: TimeInterval
    private var classFolder: URL?
    private var startedAt: Date?
    private var elapsedTimer: Timer?
    private var liveTask: Task<Void, Never>?
    private var finalTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var calibrationTask: Task<Void, Never>?
    private var liveEditPersistenceTask: Task<Void, Never>?
    private var finalJobID: UUID?
    private var retryJobID: UUID?
    private var accumulator = LiveTranscriptAccumulator()
    private var liveEditReconciler = LiveTranscriptEditReconciler()
    private var technicalVocabularyURL: URL?
    private var activeSession: ClassSessionContext?
    private var liveTranscriptionError: String?

    init(
        store: SessionStore = SessionStore(),
        capture injectedCapture: CaptureController? = nil,
        parakeet injectedParakeet: ParakeetService? = nil,
        finalProcessor injectedFinalProcessor: (any FinalProcessingProviding)? = nil,
        retryAudioPreparer: @escaping RetryAudioPreparer = prepareRetryAudio,
        liveTaskStopGrace: TimeInterval = 3,
    ) {
        let parakeet = injectedParakeet ?? ParakeetService()
        self.parakeet = parakeet
        self.store = store
        finalProcessor = injectedFinalProcessor ?? FinalProcessor(parakeet: parakeet)
        self.retryAudioPreparer = retryAudioPreparer
        self.liveTaskStopGrace = max(0, liveTaskStopGrace)
        capture = injectedCapture ?? CaptureController()
        capture.refreshSources()
        history = store.history()
        selectedApplicationID = capture.applications.first?.id
        selectedMicrophoneID = capture.microphones.first?.id
    }

    var isRecording: Bool {
        capture.isCapturing
    }

    var canStart: Bool {
        !capture.isBusy && !isStopping && !isRetrying && finalTask == nil
            && !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (mode == .online ? selectedApplication != nil : selectedMicrophone != nil)
    }

    var isProcessing: Bool {
        isRetrying || finalTask != nil || state == .finalTranscription || state == .diarizing
    }

    var isSessionBusy: Bool {
        capture.isBusy || isStopping || isProcessing
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
            return editedLiveText ?? liveVisibleText
        }
        switch selectedTab {
        case .liveEdit:
            return editedLiveText ?? liveVisibleText
        case .professor:
            let professor = editedProfessorText ?? TranscriptExporter.plainText(professorSegments)
            if !professor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return professor
            }
            return editedAllText ?? TranscriptExporter.plainText(allSegments)
        case .everyone:
            return editedAllText ?? TranscriptExporter.plainText(allSegments)
        case .review:
            return reviewItems.map { "[\($0.segment.formattedTimestamp)] \($0.reason)\n\($0.segment.text)" }.joined(separator: "\n\n")
        }
    }

    var liveVisibleText: String {
        accumulator.visibleText
    }

    /// The user-owned live transcript. ASR continues on its own accumulator;
    /// new windows are reconciled into this value without overwriting edits.
    var liveEditableText: String {
        get { editedLiveText ?? liveVisibleText }
        set { updateEditedLiveText(newValue) }
    }

    var bestAvailableText: String {
        // An explicit live edit is user-owned even when it is empty. Falling
        // back to ASR here would make Copy/Export resurrect text they deleted.
        if !finalReplacedLive, let editedLiveText {
            return editedLiveText
        }
        if finalReplacedLive, selectedTab == .liveEdit {
            return editedLiveText ?? liveVisibleText
        }
        let selectedText: String? = if !finalReplacedLive {
            liveVisibleText
        } else {
            switch selectedTab {
            case .liveEdit:
                editedLiveText ?? liveVisibleText
            case .professor:
                displayedText
            case .everyone, .review:
                editedAllText ?? TranscriptExporter.plainText(allSegments)
            }
        }
        return TranscriptActions.bestAvailable(
            preferredEdit: selectedText,
            professorEdit: editedProfessorText,
            professor: TranscriptExporter.plainText(professorSegments),
            everyoneEdit: editedAllText,
            everyone: TranscriptExporter.plainText(allSegments),
            liveEdit: editedLiveText,
            live: liveVisibleText,
        )
    }

    var hasCopyableTranscript: Bool {
        !bestAvailableText.isEmpty
    }

    var canRetryProcessing: Bool {
        guard !isSessionBusy,
              let folder = classFolder,
              let summary = history.first(where: { $0.folder.standardizedFileURL == folder.standardizedFileURL })
        else { return false }
        return summary.canRetryProcessing
    }

    var canOpenTXT: Bool {
        currentReadableTextURL != nil
    }

    var professorUnavailableWarning: String? {
        guard finalReplacedLive, professorSegments.isEmpty, !allSegments.isEmpty || editedAllText != nil else { return nil }
        return "Aún no hay profesor seleccionado; se muestra la transcripción completa."
    }

    var currentFolder: URL? {
        classFolder
    }

    var selectedExportSegments: [TranscriptSegment] {
        selectedTab == .professor && !professorSegments.isEmpty ? professorSegments : allSegments
    }

    var selectedExportHasFreeformEdit: Bool {
        switch selectedTab {
        case .liveEdit:
            true
        case .professor where !professorSegments.isEmpty:
            editedProfessorText != nil
        case .professor, .everyone, .review:
            editedAllText != nil
        }
    }

    var availableTranscriptTabs: [TranscriptTab] {
        TranscriptTab.allCases.filter { $0 != .liveEdit || editedLiveText != nil }
    }

    func refreshSources() {
        capture.refreshSources()
        if selectedApplication == nil {
            selectedApplicationID = capture.applications.first?.id
        }
        if selectedMicrophone == nil {
            selectedMicrophoneID = capture.microphones.first?.id
        }
    }

    func startClass() async {
        guard canStart else { return }
        cancelCalibration()
        guard flushEditedLiveText() else { return }
        errorMessage = nil
        liveTranscriptionError = nil
        finalReplacedLive = false
        stableLiveText = ""
        provisionalLiveText = ""
        allSegments = []
        speakers = []
        reviewItems = []
        professorSpeakerID = nil
        professorSelectionIsAutomatic = true
        editedLiveText = nil
        editedProfessorText = nil
        editedAllText = nil
        isTranscriptionPaused = false
        transcriptionLatency = 0
        elapsed = 0
        selectedTab = .professor
        accumulator = LiveTranscriptAccumulator()
        liveEditReconciler.reset()
        let now = Date()
        do {
            let folder = try store.createFolder(subject: subject, date: now)
            classFolder = folder
            startedAt = now
            technicalVocabularyURL = try makeVocabularyFile(in: folder)
            let session = ClassSessionContext(
                id: UUID(),
                folder: folder,
                subject: subject,
                startedAt: now,
                mode: mode,
                source: selectedSourceName,
                language: language,
                technicalVocabulary: technicalVocabulary,
                technicalVocabularyURL: technicalVocabularyURL,
            )
            activeSession = session
            state = .startingCapture
            statusDetail = mode == .inPerson
                ? "Esperando el primer buffer escrito antes de iniciar el contador."
                : "Iniciando la captura de audio de la aplicación seleccionada."
            try checkpointLive("session-created", session: session)
            try store.saveMetadata(metadata(session: session, state: .startingCapture), folder: folder)
            _ = try await capture.start(
                mode: mode,
                application: selectedApplication,
                microphone: selectedMicrophone,
                folder: folder,
            )
            state = .recording
            statusDetail = "El audio se guarda aunque pauses la transcripción."
            startElapsedTimer()
            startLiveTranscription(session: session)
        } catch {
            state = .failed
            errorMessage = error.localizedDescription
            statusDetail = error.localizedDescription
            persistCurrentState(checkpoint: "start-failed")
        }
    }

    func pauseTranscription() {
        guard isRecording, !isTranscriptionPaused else { return }
        isTranscriptionPaused = true
        accumulator.confirmProvisional()
        syncLiveTextFromAccumulator()
        state = .transcriptionPaused
        statusDetail = "La grabación continúa; solo se pausó la transcripción."
        persistCurrentState(checkpoint: "paused")
    }

    func resumeTranscription() {
        guard isRecording, isTranscriptionPaused else { return }
        isTranscriptionPaused = false
        state = .recording
        statusDetail = "Transcripción reanudada; el audio siguió grabándose."
        persistCurrentState(checkpoint: "resumed")
    }

    func stopClass() async {
        if let stopTask {
            await stopTask.value
            return
        }
        guard isRecording, let session = activeSession else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performStop(session: session)
        }
        stopTask = task
        await task.value
        stopTask = nil
    }

    private func performStop(session: ClassSessionContext) async {
        guard !isStopping else { return }
        isStopping = true
        cancelCalibration()
        errorMessage = nil
        state = .stopping
        statusDetail = "Guardando transcripción antes de cerrar el audio."
        _ = await stopLiveTranscription()
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        accumulator.confirmProvisional()
        syncLiveTextFromAccumulator()
        do {
            try checkpointLive("before-audio-stop", session: session)
            try store.saveMetadata(metadata(session: session, state: .stopping), folder: session.folder)
        } catch {
            errorMessage = "No se pudo completar el checkpoint previo: \(error.localizedDescription)"
        }

        do {
            state = .finalizingAudio
            statusDetail = "Cerrando y validando el audio."
            let stopped = try await capture.stop()
            elapsed = stopped.duration
            try checkpointLive("audio-stopped", session: session)
            isStopping = false
            runFinalProcessing(audioURL: stopped.url, session: session)
        } catch {
            isStopping = false
            state = .failed
            errorMessage = error.localizedDescription
            statusDetail = "El audio se conservó, pero no se pudo validar: \(error.localizedDescription)"
            persistCurrentState(checkpoint: "audio-stop-failed")
        }
    }

    func cancelFinalProcessing() {
        let cancelledRetryPreparation = retryTask != nil && finalTask == nil
        if retryTask != nil {
            retryJobID = nil
            retryTask?.cancel()
        }
        finalTask?.cancel()
        statusDetail = "Cancelando procesamiento; el texto y el audio permanecen disponibles."
        if cancelledRetryPreparation, let session = activeSession {
            state = .cancelled
            statusDetail = "Procesamiento cancelado; se conservaron el audio y el mejor texto disponible."
            persistCurrentState(checkpoint: "processing-cancelled", session: session)
        }
    }

    func selectProfessor(_ id: String) {
        professorSpeakerID = id
        professorSelectionIsAutomatic = false
        statusDetail = "Profesor cambiado a \(id); vista filtrada regenerada."
        editedProfessorText = nil
        selectedTab = .professor
        persistFinalOutputs()
        saveProfessorReference(for: id)
    }

    func toggleReviewAssignment(_ id: UUID) {
        guard let index = reviewItems.firstIndex(where: { $0.id == id }) else { return }
        reviewItems[index].manuallyAssignedToProfessor.toggle()
        editedProfessorText = nil
        persistFinalOutputs()
    }

    func calibrateProfessorVoice() {
        guard isRecording, !isCalibrating, let session = activeSession else { return }
        isCalibrating = true
        calibrationSecondsRemaining = 20
        statusDetail = "Calibración: procura que hable principalmente el profesor durante 20 segundos."
        calibrationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.calibrationTask = nil
                self.isCalibrating = false
                self.calibrationSecondsRemaining = 0
            }
            for remaining in stride(from: 20, through: 1, by: -1) {
                guard !Task.isCancelled,
                      self.isRecording,
                      self.activeSession?.id == session.id else { return }
                self.calibrationSecondsRemaining = remaining
                try? await Task.sleep(for: .seconds(1))
            }
            guard self.isRecording,
                  self.activeSession?.id == session.id,
                  let window = await self.capture.liveStore.window(seconds: 20)
            else { return }
            do {
                let url = session.folder.appendingPathComponent("professor-calibration.wav")
                try WavFile.writeFloat32(window.samples, to: url)
                let result = try await self.finalProcessor.diarize(url)
                guard self.activeSession?.id == session.id else { return }
                let durations = Dictionary(grouping: result.spans, by: \.speakerID)
                    .mapValues { $0.reduce(0) { $0 + $1.end - $1.start } }
                guard let dominant = durations.max(by: { $0.value < $1.value })?.key,
                      let embedding = result.embeddings[dominant] else {
                    throw InferenceError.modelUnavailable
                }
                let reference = ProfessorVoiceReference(
                    subject: session.subject,
                    createdAt: Date(),
                    sourceSpeakerID: dominant,
                    embedding: embedding,
                )
                try self.store.saveVoiceReference(reference, folder: session.folder)
                self.statusDetail = "Referencia local de voz calibrada. No se subió ningún dato."
            } catch is CancellationError {
                return
            } catch {
                if self.activeSession?.id == session.id {
                    self.errorMessage = "No se pudo calibrar la voz: \(error.localizedDescription)"
                }
            }
        }
    }

    func copyTranscript() {
        let text = bestAvailableText
        guard !text.isEmpty else {
            errorMessage = "Todavía no hay una transcripción para copiar."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyForChatGPT() {
        let transcript = bestAvailableText
        guard !transcript.isEmpty else {
            errorMessage = "Todavía no hay una transcripción para copiar."
            return
        }
        let context = activeSession
        let text = TranscriptActions.chatEnvelope(
            subject: context?.subject ?? subject,
            date: context?.startedAt ?? startedAt ?? Date(),
            duration: elapsed,
            mode: context?.mode ?? mode,
            source: context?.source ?? selectedSourceName,
            transcript: transcript,
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func export(_ kind: ExportKind) {
        let transcript = bestAvailableText
        let sessionSubject = activeSession?.subject ?? subject
        let sessionDate = activeSession?.startedAt ?? startedAt ?? Date()
        let timedSegments = selectedExportSegments
        let hasFreeformEdit = selectedExportHasFreeformEdit
        let format: TranscriptExportFormat = switch kind {
        case .txt: .txt
        case .markdown: .markdown
        case .srt: .srt
        }
        let plan: TranscriptExportPlan
        do {
            plan = try TranscriptExportPolicy.make(
                format: format,
                subject: sessionSubject,
                date: sessionDate,
                text: transcript,
                timedSegments: timedSegments,
                hasFreeformEdit: hasFreeformEdit,
            )
            if let warning = plan.warning {
                let alert = NSAlert()
                alert.messageText = "El SRT usa la versión segmentada"
                alert.informativeText = warning
                alert.addButton(withTitle: "Exportar SRT segmentado")
                alert.addButton(withTitle: "Cancelar")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(sessionSubject.filenameSlug.isEmpty ? "clase" : sessionSubject.filenameSlug)-transcripcion.\(kind.extensionName)"
        panel.allowedContentTypes = [kind.contentType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try plan.content.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { errorMessage = error.localizedDescription }
    }

    func updateEditedLiveText(_ text: String) {
        editedLiveText = text
        guard let session = activeSession else { return }
        scheduleLiveEditPersistence(text: text, session: session)
    }

    /// Forces the debounced edit to disk. The live editor calls this when it
    /// loses focus; Stop also flushes through `checkpointLive`.
    @discardableResult
    func flushEditedLiveText() -> Bool {
        liveEditPersistenceTask?.cancel()
        liveEditPersistenceTask = nil
        guard let text = editedLiveText, let session = activeSession else { return true }
        do {
            try store.saveReadableLiveText(
                text: text,
                context: liveContext(session: session),
                folder: session.folder,
                recordsEditOverride: true,
            )
            return true
        } catch {
            errorMessage = "No se pudo guardar la edición: \(error.localizedDescription)"
            return false
        }
    }

    func updateEditedProfessorText(_ text: String) {
        editedProfessorText = text
        persistTextEdits()
    }

    func updateEditedAllText(_ text: String) {
        editedAllText = text
        persistTextEdits()
    }

    func openCurrentFolder() {
        if let classFolder {
            NSWorkspace.shared.activateFileViewerSelecting([classFolder])
        }
    }

    func openCurrentTXT() {
        guard let url = currentReadableTextURL else {
            errorMessage = "Todavía no existe un TXT legible para esta sesión."
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openHistoryFolder(_ summary: SessionSummary) {
        NSWorkspace.shared.activateFileViewerSelecting([summary.folder])
    }

    func openHistory(_ summary: SessionSummary) {
        guard !isSessionBusy else { return }
        cancelCalibration()
        guard flushEditedLiveText() else { return }
        let restored = store.restore(summary)
        let metadata = restored.metadata
        classFolder = summary.folder
        startedAt = metadata.startedAt
        subject = metadata.subject
        mode = metadata.mode
        language = metadata.language ?? .spanish
        technicalVocabulary = metadata.technicalVocabulary
        elapsed = metadata.duration
        professorSpeakerID = metadata.professorSpeakerID
        professorSelectionIsAutomatic = metadata.professorSelectionIsAutomatic
        accumulator = restored.liveAccumulator
        liveEditReconciler.reset(asrText: accumulator.visibleText)
        syncLiveTextFromAccumulator()
        allSegments = restored.allSegments
        speakers = restored.speakers
        reviewItems = restored.review
        editedAllText = restored.editedAllText
        editedProfessorText = restored.editedProfessorText
        editedLiveText = restored.preferredTextSource == .recovered
            ? restored.preferredText
            : restored.editedLiveText
        isTranscriptionPaused = false
        finalReplacedLive = restored.preferredTextSource == .professor
            || restored.preferredTextSource == .everyone
            || !allSegments.isEmpty
        selectedTab = restored.preferredTextSource == .professor ? .professor : .everyone
        if finalReplacedLive, editedLiveText != nil {
            selectedTab = .liveEdit
        }
        state = summary.state
        statusDetail = summary.isRecoverable
            ? "Sesión recuperable cargada. El audio y el mejor texto disponible permanecen intactos."
            : "Sesión del historial cargada."
        errorMessage = summary.recoveryReason
        let vocabularyURL = summary.folder.appendingPathComponent("technical-vocabulary.txt")
        activeSession = ClassSessionContext(
            id: metadata.id,
            folder: summary.folder,
            subject: metadata.subject,
            startedAt: metadata.startedAt,
            mode: metadata.mode,
            source: metadata.source,
            language: metadata.language ?? .spanish,
            technicalVocabulary: metadata.technicalVocabulary,
            technicalVocabularyURL: FileManager.default.fileExists(atPath: vocabularyURL.path) ? vocabularyURL : nil,
        )
    }

    func retryProcessing() async {
        if let retryTask {
            await retryTask.value
            return
        }
        guard canRetryProcessing, let session = activeSession else { return }
        let jobID = UUID()
        retryJobID = jobID
        isRetrying = true
        state = .finalizingAudio
        statusDetail = "Validando el audio conservado antes de reintentar."
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRetry(session: session, jobID: jobID)
        }
        retryTask = task
        await task.value
        // A cancelled retry deliberately keeps `retryTask`/`isRetrying` set
        // until its possibly non-cooperative RAW/WAV repair has really exited.
        // No second repair may overlap the first on the same files.
        if retryJobID == jobID || retryJobID == nil {
            retryJobID = nil
            retryTask = nil
            isRetrying = false
        }
    }

    private func performRetry(session: ClassSessionContext, jobID: UUID) async {
        let audioURL = session.folder.appendingPathComponent("source.wav")
        let rawURL = session.folder.appendingPathComponent("source.raw")
        do {
            let preparation = try await retryAudioPreparer(audioURL, rawURL)
            try ensureCurrentRetry(jobID: jobID, session: session)
            elapsed = preparation.duration
            errorMessage = nil
            statusDetail = preparation.recoveredRaw
                ? "Audio recuperado; reintentando el procesamiento."
                : "Audio listo; reintentando el procesamiento."
            try store.saveMetadata(metadata(session: session, state: .finalizingAudio), folder: session.folder)
            runFinalProcessing(audioURL: audioURL, session: session, reusePersistedTranscript: !allSegments.isEmpty)
        } catch is CancellationError {
            return
        } catch {
            guard retryJobID == jobID, activeSession?.id == session.id else { return }
            state = .recoverable
            errorMessage = "No se puede reprocesar el audio: \(error.localizedDescription)"
            statusDetail = "El texto recuperado sigue disponible."
            persistCurrentState(checkpoint: "audio-recovery-failed", session: session)
        }
    }

    private func ensureCurrentRetry(jobID: UUID, session: ClassSessionContext) throws {
        guard retryJobID == jobID, activeSession?.id == session.id else { throw CancellationError() }
    }

    func waitForFinalProcessingForTesting() async {
        await finalTask?.value
    }

    private func startElapsedTimer() {
        elapsed = 0
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startedAt = self.startedAt else { return }
                if let failure = self.capture.takeTerminalFailure() {
                    await self.failActiveCapture(failure)
                    return
                }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    private func failActiveCapture(_ message: String) async {
        guard !isStopping, let session = activeSession else { return }
        isStopping = true
        cancelCalibration()
        state = .stopping
        statusDetail = "Cerrando y validando el audio después del error del micrófono."
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        _ = await stopLiveTranscription()
        accumulator.confirmProvisional()
        syncLiveTextFromAccumulator()
        // A terminal channel failure is reported before the controller tears
        // down so this path can use the normal idempotent stop/finalization.
        // In particular, an online RAW track must be wrapped into source.wav
        // before validation and recovery metadata are written.
        await capture.abortPreservingAudio()
        let audioURL = session.folder.appendingPathComponent("source.wav")
        let validation = await Task.detached(priority: .userInitiated) {
            Result { try WavFile.validate(audioURL) }
        }.value
        guard activeSession?.id == session.id else {
            isStopping = false
            return
        }
        switch validation {
        case let .success(duration):
            elapsed = duration
            state = .recoverable
            errorMessage = message
            statusDetail = "La captura se detuvo, pero el audio se conservó y puede reprocesarse."
        case let .failure(validationError):
            state = .failed
            errorMessage = "\(message) El audio no pudo validarse: \(validationError.localizedDescription)"
            statusDetail = "La captura se detuvo y el audio quedó conservado para diagnóstico."
        }
        persistCurrentState(checkpoint: "capture-failed", session: session)
        isStopping = false
    }

    /// Cancel live inference and give it a short grace period to observe that
    /// cancellation. Core ML occasionally finishes a prediction before it can
    /// check cancellation; Stop must still proceed and finalize the durable WAV.
    /// The live task checks both cancellation and `session.id` before every
    /// post-inference mutation, so a late result cannot touch a newer session.
    private func stopLiveTranscription() async -> Bool {
        guard let task = liveTask else { return true }
        task.cancel()
        let finished = await TaskCompletionGracePeriod.wait(for: task, timeout: liveTaskStopGrace)
        liveTask = nil
        return finished
    }

    private func startLiveTranscription(session: ClassSessionContext) {
        liveTask?.cancel()
        liveTask = Task { [weak self] in
            guard let self else { return }
            var cursor = LiveTranscriptionCursor() // 5.5-second hops; 1.5-second overlap in a 7-second window
            var retryPolicy = LiveTranscriptionRetryPolicy()
            var resumeAtLatestWindow = false
            while !Task.isCancelled, self.isRecording {
                do { try await Task.sleep(for: .milliseconds(400)) }
                catch { break }
                guard !Task.isCancelled, self.activeSession?.id == session.id else { break }
                guard !self.isTranscriptionPaused else {
                    // Pausing live inference must not build an unbounded queue
                    // that is replayed when the user resumes.
                    resumeAtLatestWindow = true
                    continue
                }
                let uptime = ProcessInfo.processInfo.systemUptime
                guard retryPolicy.canAttempt(atUptime: uptime) else { continue }
                let total = await self.capture.liveStore.totalSamples()
                guard var windowEnd = cursor.nextWindowEnd(
                    totalSamples: total,
                    preferLatest: resumeAtLatestWindow,
                ) else { continue }
                resumeAtLatestWindow = false
                var skippedExpiredSamples: Int64 = 0
                var window = await self.capture.liveStore.window(
                    seconds: 7,
                    endingAt: windowEnd,
                    requiresCompleteHistory: true,
                )
                if window == nil,
                   let recovery = cursor.recoverFromExpiredWindow(totalSamples: total) {
                    windowEnd = recovery.end
                    skippedExpiredSamples = recovery.skippedSamples
                    window = await self.capture.liveStore.window(
                        seconds: 7,
                        endingAt: windowEnd,
                        requiresCompleteHistory: true,
                    )
                }
                guard let window else { continue }
                // Measure the pause at the edge of this exact ASR window. Core
                // ML may return later, after newer speech has entered the ring.
                let pauseDuration = await self.capture.liveStore.recentSilenceDuration(
                    endingAt: windowEnd,
                )
                let began = Date()
                do {
                    self.state = .loadingModel
                    self.statusDetail = skippedExpiredSamples > 0
                        ? "La vista en vivo retomó el audio reciente; la versión final recuperará el tramo anterior."
                        : "Preparando la transcripción local…"
                    let text = try await self.parakeet.transcribe(
                        samples: window.samples,
                        language: session.language,
                    )
                    try Task.checkCancellation()
                    guard self.activeSession?.id == session.id, self.isRecording else { break }
                    guard !self.isTranscriptionPaused else {
                        // The user paused while Core ML was still returning a
                        // result. Discard it and resume from recent audio later;
                        // never overwrite the paused UI/state with a late result.
                        resumeAtLatestWindow = true
                        continue
                    }
                    let pause = pauseDuration >= 0.55
                    try Task.checkCancellation()
                    guard self.activeSession?.id == session.id, self.isRecording else { break }
                    guard !self.isTranscriptionPaused else {
                        resumeAtLatestWindow = true
                        continue
                    }
                    self.accumulator.accept(
                        text,
                        start: window.start,
                        end: Double(windowEnd) / 16000,
                        confirmedByPause: pause,
                        pauseDuration: pauseDuration,
                    )
                    cursor.commit(windowEndingAt: windowEnd)
                    retryPolicy.recordSuccess()
                    self.syncLiveTextFromAccumulator()
                    if self.errorMessage == self.liveTranscriptionError {
                        self.errorMessage = nil
                    }
                    self.liveTranscriptionError = nil
                    self.transcriptionLatency = Date().timeIntervalSince(began) + 1.5
                    self.state = .recording
                    self.statusDetail = pause
                        ? "Texto actualizado. Puedes corregirlo mientras la grabación continúa."
                        : "Puedes corregir el texto mientras la grabación continúa."
                    do { try self.checkpointLive("asr-window", session: session) }
                    catch { self.errorMessage = "No se pudo actualizar live-transcript.txt: \(error.localizedDescription)" }
                } catch is CancellationError {
                    break
                } catch {
                    guard !Task.isCancelled, self.activeSession?.id == session.id, self.isRecording else { break }
                    let delay = retryPolicy.recordFailure(atUptime: ProcessInfo.processInfo.systemUptime)
                    self.state = .recording
                    let previousLiveError = self.liveTranscriptionError
                    let message = "Transcripción en vivo no disponible: \(error.localizedDescription). La grabación continúa."
                    self.liveTranscriptionError = message
                    if self.errorMessage == nil || self.errorMessage == previousLiveError {
                        self.errorMessage = message
                    }
                    self.statusDetail = "La grabación continúa; reintento en \(Int(delay)) s y retranscripción final al detener."
                }
            }
        }
    }

    private func runFinalProcessing(
        audioURL: URL,
        session: ClassSessionContext,
        reusePersistedTranscript: Bool = false,
    ) {
        guard finalTask == nil else {
            errorMessage = "Ya hay un procesamiento final en curso."
            return
        }
        let jobID = UUID()
        finalJobID = jobID
        finalTask = Task { [weak self] in
            guard let self else { return }
            do {
                try self.ensureCurrentFinalJob(jobID: jobID, session: session)
                var vocabularyWarning: String?
                let transcript: [TranscriptSegment]
                if reusePersistedTranscript, !self.allSegments.isEmpty {
                    transcript = self.allSegments
                    self.statusDetail = "La transcripción completa ya estaba guardada; se reintenta la identificación de voces."
                    try self.store.saveMetadata(
                        self.metadata(session: session, state: .diarizing),
                        folder: session.folder,
                    )
                } else {
                    self.state = .finalTranscription
                    self.statusDetail = "La versión en vivo permanece visible mientras se prepara la versión completa."
                    await self.finalProcessor.configureLanguage(session.language)
                    do {
                        try await self.finalProcessor.configureVocabulary(file: session.technicalVocabularyURL)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // Custom vocabulary is an optional accuracy boost. A
                        // missing CTC model or malformed list must not discard
                        // an otherwise valid full-file transcription.
                        let warning = "No se pudo aplicar el vocabulario técnico; la transcripción base continuó."
                        vocabularyWarning = warning
                        self.statusDetail = warning
                    }
                    try self.ensureCurrentFinalJob(jobID: jobID, session: session)
                    transcript = try await self.finalProcessor.transcribe(audioURL)
                    try Task.checkCancellation()
                    try self.ensureCurrentFinalJob(jobID: jobID, session: session)
                    guard !transcript.isEmpty else { throw SessionStoreError.emptyTranscript }
                    self.allSegments = transcript
                    self.editedAllText = nil
                    self.editedProfessorText = nil
                    try self.store.saveFullTranscript(
                        metadata: self.metadata(session: session, state: .diarizing),
                        segments: transcript,
                        folder: session.folder,
                    )
                }
                self.finalReplacedLive = true
                if self.editedLiveText != nil {
                    self.selectedTab = .liveEdit
                } else if self.professorSegments.isEmpty {
                    self.selectedTab = .everyone
                }
                self.state = .diarizing
                self.statusDetail = "Identificando las voces de la clase…"
                let diarization = try await self.finalProcessor.diarize(audioURL)
                try Task.checkCancellation()
                try self.ensureCurrentFinalJob(jobID: jobID, session: session)
                let assignment = SpeakerAssignment.assign(transcript: transcript, diarization: diarization.spans)
                self.allSegments = assignment.segments
                self.reviewItems = assignment.review
                self.speakers = self.makeSpeakers(spans: diarization.spans, embeddings: diarization.embeddings)
                self.editedProfessorText = nil
                self.chooseProfessorAutomatically(subject: session.subject, embeddings: diarization.embeddings)
                self.finalReplacedLive = true
                self.state = .complete
                self.statusDetail = vocabularyWarning
                    ?? (self.editedLiveText == nil
                        ? "La transcripción final reemplazó a la versión provisional."
                        : "La versión final está lista y tus correcciones permanecen en Mi edición.")
                if !self.persistFinalOutputs(session: session) {
                    self.state = .recoverable
                    self.statusDetail = "El texto sigue disponible, pero no se pudieron confirmar todas las salidas finales."
                }
            } catch is CancellationError {
                if self.isCurrentFinalJob(jobID: jobID, session: session) {
                    self.state = .cancelled
                    self.statusDetail = "Procesamiento cancelado; se conservaron el audio y el texto en vivo."
                    self.persistCurrentState(checkpoint: "processing-cancelled", session: session)
                }
            } catch {
                if self.isCurrentFinalJob(jobID: jobID, session: session) {
                    self.state = .failed
                    self.errorMessage = error.localizedDescription
                    self.statusDetail = self.allSegments.isEmpty
                        ? "Falló la transcripción final; se conserva el texto en vivo."
                        : "La transcripción completa está guardada; falló la identificación de hablantes y puede reintentarse."
                    self.persistCurrentState(checkpoint: "processing-failed", session: session)
                }
            }
            if self.finalJobID == jobID {
                self.finalJobID = nil
                self.finalTask = nil
            }
            self.refreshHistory()
        }
    }

    private func ensureCurrentFinalJob(jobID: UUID, session: ClassSessionContext) throws {
        guard isCurrentFinalJob(jobID: jobID, session: session) else { throw CancellationError() }
    }

    private func isCurrentFinalJob(jobID: UUID, session: ClassSessionContext) -> Bool {
        finalJobID == jobID && activeSession?.id == session.id
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
                embedding: embeddings[id],
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

    private func chooseProfessorAutomatically(subject: String, embeddings: [String: [Float]]) {
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
        guard let session = activeSession,
              let embedding = speakers.first(where: { $0.id == id })?.embedding else { return }
        let reference = ProfessorVoiceReference(
            subject: session.subject,
            createdAt: Date(),
            sourceSpeakerID: id,
            embedding: embedding,
        )
        try? store.saveVoiceReference(reference, folder: session.folder)
    }

    private func metadata(session: ClassSessionContext, state override: ProcessingState? = nil) -> ClassMetadata {
        ClassMetadata(
            id: session.id,
            subject: session.subject,
            startedAt: session.startedAt,
            duration: elapsed,
            mode: session.mode,
            source: session.source,
            professorSpeakerID: professorSpeakerID,
            professorSelectionIsAutomatic: professorSelectionIsAutomatic,
            speakerCount: speakers.count,
            state: override ?? state,
            folderPath: session.folder.path,
            technicalVocabulary: session.technicalVocabulary,
            language: session.language,
        )
    }

    @discardableResult
    private func persistFinalOutputs(session: ClassSessionContext? = nil) -> Bool {
        guard let session = session ?? activeSession else { return false }
        do {
            try store.saveFinal(
                metadata: metadata(session: session),
                all: allSegments,
                professor: professorSegments,
                review: reviewItems,
                speakers: speakers,
                folder: session.folder,
                editedAllText: editedAllText,
                editedProfessorText: editedProfessorText,
            )
            refreshHistory()
            return true
        } catch {
            errorMessage = "No se pudo guardar una exportación: \(error.localizedDescription)"
            refreshHistory()
            return false
        }
    }

    private func persistCurrentState(checkpoint: String, session: ClassSessionContext? = nil) {
        guard let session = session ?? activeSession else { return }
        do {
            try store.saveMetadata(metadata(session: session), folder: session.folder)
            try checkpointLive(checkpoint, session: session)
            if !allSegments.isEmpty {
                try store.saveFinal(
                    metadata: metadata(session: session),
                    all: allSegments,
                    professor: professorSegments,
                    review: reviewItems,
                    speakers: speakers,
                    folder: session.folder,
                    editedAllText: editedAllText,
                    editedProfessorText: editedProfessorText,
                )
            }
        } catch {
            errorMessage = "No se pudo guardar el estado de recuperación: \(error.localizedDescription)"
        }
        refreshHistory()
    }

    private func checkpointLive(_ checkpoint: String, session: ClassSessionContext) throws {
        // A checkpoint is also an immediate flush of the latest edit. Cancel a
        // pending typing debounce so it cannot rewrite this newer snapshot.
        liveEditPersistenceTask?.cancel()
        liveEditPersistenceTask = nil
        try store.saveLive(
            accumulator: accumulator,
            context: LiveTranscriptContext(
                subject: session.subject,
                startedAt: session.startedAt,
                mode: session.mode,
                source: session.source,
                duration: elapsed,
            ),
            folder: session.folder,
            checkpoint: checkpoint,
            visibleTextOverride: editedLiveText,
        )
    }

    private func persistTextEdits() {
        guard let session = activeSession else { return }
        do {
            try store.saveTextOverrides(
                metadata: metadata(session: session),
                allText: editedAllText,
                professorText: editedProfessorText,
                folder: session.folder,
            )
        } catch { errorMessage = "No se pudo guardar la edición: \(error.localizedDescription)" }
    }

    private func liveContext(session: ClassSessionContext) -> LiveTranscriptContext {
        LiveTranscriptContext(
            subject: session.subject,
            startedAt: session.startedAt,
            mode: session.mode,
            source: session.source,
            duration: elapsed,
        )
    }

    private func scheduleLiveEditPersistence(text: String, session: ClassSessionContext) {
        liveEditPersistenceTask?.cancel()
        liveEditPersistenceTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { return }
            guard let self,
                  self.activeSession?.id == session.id,
                  self.editedLiveText == text else { return }
            do {
                try self.store.saveReadableLiveText(
                    text: text,
                    context: self.liveContext(session: session),
                    folder: session.folder,
                    recordsEditOverride: true,
                )
            } catch {
                self.errorMessage = "No se pudo guardar la edición: \(error.localizedDescription)"
            }
            self.liveEditPersistenceTask = nil
        }
    }

    private func refreshHistory() {
        history = store.scanSessions()
    }

    var currentReadableTextURL: URL? {
        guard let folder = classFolder else { return nil }
        let existing: ([String]) -> URL? = { candidates in
            candidates.map { folder.appendingPathComponent($0) }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }
        if selectedTab == .liveEdit || !finalReplacedLive,
           let live = existing(["live-transcript.txt"]) {
            return live
        }
        if finalReplacedLive {
            let selectedCandidates: [String] = switch selectedTab {
            case .liveEdit:
                ["live-transcript.txt"]
            case .professor where !professorSegments.isEmpty || editedProfessorText != nil:
                ["professor.txt", "all-speakers.txt"]
            case .professor, .everyone, .review:
                ["all-speakers.txt", "professor.txt"]
            }
            if let selected = existing(selectedCandidates) {
                return selected
            }
        }
        if let summary = history.first(where: { $0.folder.standardizedFileURL == folder.standardizedFileURL }),
           let url = summary.preferredTextURL {
            return url
        }
        let candidates = ["professor.txt", "all-speakers.txt", "recovered-transcript.txt", "live-transcript.txt"]
        return existing(candidates)
    }

    private func syncLiveTextFromAccumulator() {
        let updatedASRText = accumulator.visibleText
        stableLiveText = accumulator.stableText
        provisionalLiveText = accumulator.provisionalText
        if let reconciled = liveEditReconciler.reconcile(
            editedText: editedLiveText,
            updatedASRText: updatedASRText,
        ) {
            editedLiveText = reconciled
        }
    }

    private func cancelCalibration() {
        calibrationTask?.cancel()
    }
}

enum ExportKind: String, CaseIterable, Identifiable {
    case txt = "TXT"
    case markdown = "Markdown"
    case srt = "SRT"
    var id: String {
        rawValue
    }

    var extensionName: String {
        self == .markdown ? "md" : rawValue.lowercased()
    }

    var contentType: UTType {
        switch self {
        case .txt: .plainText
        case .markdown: UTType(filenameExtension: "md") ?? .plainText
        case .srt: UTType(filenameExtension: "srt") ?? .plainText
        }
    }
}
