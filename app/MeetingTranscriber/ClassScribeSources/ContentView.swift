import SwiftUI

enum CapturePrimaryControlState: Equatable {
    case ready
    case starting
    case recording(paused: Bool)
    case stopping
    case processing

    static func resolve(
        isStopping: Bool,
        isStarting: Bool,
        isRecording: Bool,
        isPaused: Bool,
        isProcessing: Bool,
    ) -> Self {
        if isStopping { return .stopping }
        if isStarting { return .starting }
        if isRecording { return .recording(paused: isPaused) }
        if isProcessing { return .processing }
        return .ready
    }
}

enum CaptureStartGuidance: Equatable {
    case ready
    case subjectRequired
    case sourceRequired(CaptureMode)

    static func resolve(subject: String, mode: CaptureMode, hasSelectedSource: Bool) -> Self {
        if subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .subjectRequired
        }
        if !hasSelectedSource {
            return .sourceRequired(mode)
        }
        return .ready
    }

    var message: String? {
        switch self {
        case .ready:
            nil
        case .subjectRequired:
            "Escribe el nombre de la materia."
        case .sourceRequired(.online):
            "Elige la aplicación donde está la clase."
        case .sourceRequired(.inPerson):
            "Elige el micrófono que quieres usar."
        }
    }
}

struct LiveTranscriptFollowPresentation: Equatable {
    var message: String
    var actionTitle: String?
    var systemImage: String

    static func resolve(
        isFollowing: Bool,
        isEditing: Bool,
        hasUnseenText: Bool,
    ) -> LiveTranscriptFollowPresentation {
        if isFollowing {
            return LiveTranscriptFollowPresentation(
                message: "Siguiendo la transcripción automáticamente.",
                actionTitle: nil,
                systemImage: "arrow.down.to.line.compact",
            )
        }
        if hasUnseenText {
            return LiveTranscriptFollowPresentation(
                message: "Hay texto nuevo; tu cursor y tu posición no se movieron.",
                actionTitle: "Ver texto nuevo",
                systemImage: "text.badge.plus",
            )
        }
        return LiveTranscriptFollowPresentation(
            message: isEditing
                ? "Edición activa: tu cursor y tu posición quedan fijos."
                : "Seguimiento pausado para que puedas revisar el texto.",
            actionTitle: "Seguir en vivo",
            systemImage: isEditing ? "character.cursor.ibeam" : "pause.circle",
        )
    }
}

struct ContentView: View {
    @Bindable var model: ClassScribeModel
    @State private var showsTechnicalVocabulary = false
    @State private var liveEditorIsEditing = false
    @State private var followsLiveTranscript = true
    @State private var hasUnseenLiveTranscript = false

    var body: some View {
        VStack(spacing: 0) {
            header
            captureConfiguration
            statusBar
            if model.errorMessage != nil {
                errorBanner
            }
            Divider()
            HSplitView {
                speakersPanel
                    .frame(minWidth: 245, idealWidth: 280, maxWidth: 330)
                    .frame(maxHeight: .infinity, alignment: .top)
                transcriptPanel
                    .frame(minWidth: 700)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.indigo.gradient)
                    .frame(width: 42, height: 42)
                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("ClassScribe")
                    .font(.title2.bold())
                Text("Graba y transcribe tus clases en esta Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .help(BuildIdentity.provenanceLabel)
            Spacer()
            Label("Procesamiento local", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var captureConfiguration: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configura la clase")
                .font(.headline)

            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Materia")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    TextField("Ej.: Análisis matemático", text: $model.subject)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.isSessionBusy)
                }
                .frame(minWidth: 210, idealWidth: 250)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Tipo de clase")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Picker("Tipo de clase", selection: $model.mode) {
                        ForEach(CaptureMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .disabled(model.isSessionBusy)
                }
                .frame(width: 240)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Idioma")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Picker("Idioma de transcripción", selection: $model.language) {
                        ForEach(TranscriptionLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .labelsHidden()
                    .disabled(model.isSessionBusy)
                }
                .frame(width: 105)

                VStack(alignment: .leading, spacing: 5) {
                    Text(model.mode == .online ? "Aplicación" : "Micrófono")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        sourcePicker
                        Button {
                            model.refreshSources()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Actualizar fuentes de audio")
                        .accessibilityLabel("Actualizar fuentes de audio")
                    }
                    .disabled(model.isSessionBusy)
                }
                .frame(minWidth: 250, idealWidth: 300)

                Spacer(minLength: 0)
                primaryCaptureControls
            }

            DisclosureGroup(isExpanded: $showsTechnicalVocabulary) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Ayuda a reconocer nombres, siglas y términos propios de la materia.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(
                        "Ej.: Newton-Raphson, Runge-Kutta, PMBOK",
                        text: $model.technicalVocabulary,
                    )
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isSessionBusy)
                }
                .padding(.top, 7)
            } label: {
                Label("Agregar vocabulario técnico (opcional)", systemImage: "text.badge.plus")
                    .font(.caption)
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.07))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var sourcePicker: some View {
        if model.mode == .online {
            Picker("Aplicación", selection: $model.selectedApplicationIdentityID) {
                Text("Seleccionar aplicación…").tag(String?.none)
                ForEach(model.capture.applications) { app in
                    Text(app.name).tag(String?.some(app.id))
                }
            }
            .labelsHidden()
            .frame(minWidth: 220)
        } else {
            Picker("Micrófono", selection: $model.selectedMicrophoneID) {
                Text("Seleccionar micrófono…").tag(String?.none)
                ForEach(model.capture.microphones) { mic in
                    Text(mic.name).tag(String?.some(mic.id))
                }
            }
            .labelsHidden()
            .frame(minWidth: 220)
        }
    }

    private var primaryControlState: CapturePrimaryControlState {
        .resolve(
            isStopping: model.isStopping,
            isStarting: model.capture.isStarting,
            isRecording: model.isRecording,
            isPaused: model.isTranscriptionPaused,
            isProcessing: model.isProcessing,
        )
    }

    private var startGuidance: CaptureStartGuidance {
        .resolve(
            subject: model.subject,
            mode: model.mode,
            hasSelectedSource: model.mode == .online
                ? model.selectedApplication != nil
                : model.selectedMicrophone != nil,
        )
    }

    @ViewBuilder
    private var primaryCaptureControls: some View {
        VStack(alignment: .trailing, spacing: 5) {
            switch primaryControlState {
            case .stopping:
                progressLabel("Guardando…")
            case .starting:
                HStack(spacing: 8) {
                    progressLabel("Conectando al audio…")
                    Button("Cancelar", role: .cancel) {
                        model.cancelStart()
                    }
                }
            case let .recording(paused):
                HStack(spacing: 8) {
                    Button {
                        paused ? model.resumeTranscription() : model.pauseTranscription()
                    } label: {
                        Label(
                            paused ? "Reanudar" : "Pausar texto",
                            systemImage: paused ? "play.fill" : "pause.fill",
                        )
                    }
                    Button(role: .destructive) {
                        Task { await model.stopClass() }
                    } label: {
                        Label("Finalizar", systemImage: "stop.fill")
                    }
                }
            case .processing:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    if model.isRetrying || model.state == .finalTranscription || model.state == .diarizing {
                        Button("Cancelar procesamiento", role: .cancel) {
                            model.cancelFinalProcessing()
                        }
                    }
                }
            case .ready:
                Button {
                    Task { await model.startClass() }
                } label: {
                    Label("Iniciar grabación", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canStart)
                if !model.canStart, let message = startGuidance.message {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 175, alignment: .trailing)
    }

    private func progressLabel(_ title: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .font(.subheadline)
        }
        .foregroundStyle(.secondary)
    }

    private var statusBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 7) {
                Circle()
                    .fill(model.isRecording ? .red : statusColor)
                    .frame(width: 10, height: 10)
                Text(statusTitle)
                    .font(.subheadline.bold())
            }
            if model.isRecording || model.elapsed > 0 {
                Label(Timecode.display(model.elapsed), systemImage: "timer")
                    .font(.subheadline)
                    .monospacedDigit()
            }
            if model.isRecording {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .foregroundStyle(.secondary)
                    Gauge(value: min(0, max(-60, model.capture.levelDBFS)), in: -60 ... 0) {
                        Text("Nivel de audio")
                    }
                    .labelsHidden()
                    .gaugeStyle(.accessoryLinearCapacity)
                    .frame(width: 92)
                    .accessibilityLabel("Nivel de audio")
                }
            }
            Text(model.statusDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            if model.canRetryProcessing {
                Button {
                    Task { await model.retryProcessing() }
                } label: {
                    Label("Reintentar procesamiento", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var statusTitle: String {
        if model.isRecording {
            return model.isTranscriptionPaused ? "Grabando · texto pausado" : "Grabando y transcribiendo"
        }
        return model.state.rawValue
    }

    private var statusColor: Color {
        switch model.state {
        case .complete: .green
        case .failed: .red
        case .cancelled, .recoverable: .orange
        case .ready: .secondary
        default: .blue
        }
    }

    private var speakersPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Voces", systemImage: "person.2.wave.2")
                    .font(.headline)
                Spacer()
                if !model.speakers.isEmpty {
                    Text("\(model.speakers.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if model.speakers.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "person.2.wave.2")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Aún no hay voces identificadas")
                        .font(.subheadline.bold())
                    Text("Se identificarán al finalizar la grabación.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.speakers) { speaker in
                            speakerCard(speaker)
                        }
                    }
                }
                .frame(maxHeight: 315)
            }

            if model.isRecording {
                Button {
                    model.calibrateProfessorVoice()
                } label: {
                    Label(
                        model.isCalibrating
                            ? "Guardando voz… \(model.calibrationSecondsRemaining) s"
                            : "Guardar voz del profesor (20 s)",
                        systemImage: "waveform.badge.mic",
                    )
                }
                .disabled(model.isCalibrating || model.isStopping)
                .help("Crea una referencia local para reconocer al profesor en esta materia.")
            }

            if let professor = model.professorSpeakerID {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Profesor: \(professor)", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.subheadline.bold())
                        .foregroundStyle(.indigo)
                    if model.professorSelectionIsAutomatic {
                        Text("Selección automática; puedes cambiarla.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()
            HStack {
                Label("Clases anteriores", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                if !model.history.isEmpty {
                    Text("\(model.history.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if model.history.isEmpty {
                Text("Tus grabaciones aparecerán aquí.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(model.history) { item in
                            Button {
                                model.openHistory(item)
                            } label: {
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.subject)
                                            .font(.subheadline.bold())
                                            .lineLimit(1)
                                        Text(
                                            "\(item.startedAt.formatted(date: .abbreviated, time: .shortened)) · "
                                                + Timecode.display(item.duration),
                                        )
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        if item.isRecoverable {
                                            Text("Necesita recuperar el procesamiento")
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(Color.secondary.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isSessionBusy)
                        }
                    }
                }
            }
        }
        .padding(14)
    }

    private func speakerCard(_ speaker: SpeakerRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(speaker.displayName).font(.subheadline.bold())
                Spacer()
                Text(Timecode.display(speaker.totalSpeakingTime)).font(.caption.monospacedDigit())
            }
            if let sample = speaker.recentFragments.last {
                Text("“\(sample)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack {
                Spacer()
                Button(professorButtonTitle(for: speaker)) {
                    model.selectProfessor(speaker.id)
                }
                .controlSize(.mini)
                .disabled(model.professorSpeakerID == speaker.id && !model.professorSelectionIsAutomatic)
            }
        }
        .padding(8)
        .background(model.professorSpeakerID == speaker.id ? Color.indigo.opacity(0.12) : Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func professorButtonTitle(for speaker: SpeakerRecord) -> String {
        guard model.professorSpeakerID == speaker.id else { return "Elegir como profesor" }
        return model.professorSelectionIsAutomatic ? "Confirmar profesor" : "Profesor ✓"
    }

    private var transcriptPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if model.finalReplacedLive {
                    Picker("Transcripción", selection: $model.selectedTab) {
                        ForEach(model.availableTranscriptTabs) { tab in
                            Text(
                                tab.rawValue
                                    + (tab == .review && !model.reviewItems.isEmpty
                                        ? " (\(model.reviewItems.count))"
                                        : ""),
                            )
                            .tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 500)
                } else {
                    Label(
                        model.isRecording ? "Transcripción en vivo" : "Transcripción",
                        systemImage: "text.alignleft",
                    )
                    .font(.headline)
                }
                if let actionTitle = liveFollowPresentation.actionTitle,
                   model.isRecording {
                    Button {
                        resumeLiveTranscriptFollowing()
                    } label: {
                        Label(actionTitle, systemImage: "arrow.down.to.line.compact")
                    }
                    .controlSize(.small)
                    .help("Volver al texto más reciente y continuar siguiéndolo")
                }
                Spacer()
                if model.isProcessing {
                    ProgressView()
                        .controlSize(.small)
                }
                if model.hasCopyableTranscript || model.currentFolder != nil {
                    transcriptActions
                }
            }
            .padding(12)

            Divider()

            if model.isRecording {
                liveTranscript
            } else if model.finalReplacedLive && model.selectedTab == .review {
                reviewPanel
            } else if !model.hasCopyableTranscript {
                ContentUnavailableView(
                    "La transcripción aparecerá aquí",
                    systemImage: "text.quote",
                    description: Text("Configura la clase y pulsa Iniciar grabación."),
                )
            } else {
                TextEditor(text: editableText)
                    .font(.system(.body, design: .rounded))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor))
            }

            if model.isRecording {
                HStack {
                    Image(systemName: liveFollowPresentation.systemImage)
                        .foregroundStyle(followsLiveTranscript ? .indigo : .orange)
                    Text(liveFollowPresentation.message)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(9)
                .background((followsLiveTranscript ? Color.indigo : Color.orange).opacity(0.06))
            } else if model.finalReplacedLive, model.selectedTab == .liveEdit {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Tus correcciones se conservaron. Puedes compararlas con la transcripción final en las otras pestañas.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(9)
                .background(Color.green.opacity(0.08))
            } else if let warning = model.professorUnavailableWarning, model.selectedTab == .professor {
                HStack {
                    Image(systemName: "person.crop.circle.badge.questionmark").foregroundStyle(.orange)
                    Text(warning).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(9)
                .background(Color.orange.opacity(0.08))
            } else if model.finalReplacedLive {
                HStack {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("La versión final reemplazó la provisional; puedes editar y exportar el texto.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(9)
                .background(Color.green.opacity(0.08))
            }
        }
    }

    private var transcriptActions: some View {
        Menu {
            Button {
                model.copyTranscript()
            } label: {
                Label("Copiar transcripción", systemImage: "doc.on.doc")
            }
            .disabled(!model.hasCopyableTranscript)

            Button {
                model.copyForChatGPT()
            } label: {
                Label("Copiar con contexto", systemImage: "text.badge.plus")
            }
            .disabled(!model.hasCopyableTranscript)

            Divider()

            Button {
                model.openCurrentTXT()
            } label: {
                Label("Abrir archivo de texto", systemImage: "doc.text")
            }
            .disabled(!model.canOpenTXT)

            Button {
                model.openCurrentFolder()
            } label: {
                Label("Mostrar carpeta en Finder", systemImage: "folder")
            }
            .disabled(model.currentFolder == nil)

            Divider()

            ForEach(ExportKind.allCases) { kind in
                Button {
                    model.export(kind)
                } label: {
                    Label("Exportar \(kind.rawValue)", systemImage: "square.and.arrow.up")
                }
                .disabled(!model.hasCopyableTranscript)
            }
        } label: {
            Label("Acciones", systemImage: "ellipsis.circle")
        }
    }

    private var liveTranscript: some View {
        ZStack(alignment: .topLeading) {
            LiveTranscriptEditor(
                text: liveEditableText,
                isEditing: $liveEditorIsEditing,
                isFollowing: $followsLiveTranscript,
                onFinalize: { _ = model.flushEditedLiveText() },
            )
            if model.liveEditableText.isEmpty {
                Text("La transcripción aparecerá aquí mientras habla el profesor…")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 18)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: liveEditorIsEditing) { _, isEditing in
            if !isEditing {
                model.flushEditedLiveText()
            }
        }
        .onChange(of: model.liveVisibleText) { _, _ in
            if !followsLiveTranscript {
                hasUnseenLiveTranscript = true
            }
        }
        .onAppear {
            liveEditorIsEditing = false
            followsLiveTranscript = true
            hasUnseenLiveTranscript = false
        }
        .onDisappear {
            _ = model.flushEditedLiveText()
            liveEditorIsEditing = false
            followsLiveTranscript = true
            hasUnseenLiveTranscript = false
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var liveFollowPresentation: LiveTranscriptFollowPresentation {
        LiveTranscriptFollowPresentation.resolve(
            isFollowing: followsLiveTranscript,
            isEditing: liveEditorIsEditing,
            hasUnseenText: hasUnseenLiveTranscript,
        )
    }

    private func resumeLiveTranscriptFollowing() {
        _ = model.flushEditedLiveText()
        hasUnseenLiveTranscript = false
        followsLiveTranscript = true
    }

    private var liveEditableText: Binding<String> {
        Binding(
            get: { model.liveEditableText },
            set: { model.liveEditableText = $0 },
        )
    }

    private var editableText: Binding<String> {
        Binding(
            get: {
                if !model.finalReplacedLive {
                    return model.editedLiveText ?? model.liveVisibleText
                }
                switch model.selectedTab {
                case .liveEdit:
                    return model.editedLiveText ?? model.liveVisibleText
                case .professor:
                    return model.editedProfessorText
                        ?? (model.professorSegments.isEmpty
                            ? (model.editedAllText ?? TranscriptExporter.plainText(model.allSegments))
                            : TranscriptExporter.plainText(model.professorSegments))
                case .everyone:
                    return model.editedAllText ?? TranscriptExporter.plainText(model.allSegments)
                case .review: return ""
                }
            },
            set: { newValue in
                if !model.finalReplacedLive {
                    model.updateEditedLiveText(newValue)
                } else if model.selectedTab == .liveEdit {
                    model.updateEditedLiveText(newValue)
                } else if model.selectedTab == .professor, !model.professorSegments.isEmpty {
                    model.updateEditedProfessorText(newValue)
                } else if model.selectedTab == .everyone || model.selectedTab == .professor {
                    model.updateEditedAllText(newValue)
                }
            },
        )
    }

    private var errorBanner: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(model.errorMessage ?? "")
                .font(.caption)
                .textSelection(.enabled)
            Spacer()
            Button("Ocultar") { model.errorMessage = nil }
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }

    @ViewBuilder
    private var reviewPanel: some View {
        if model.reviewItems.isEmpty {
            ContentUnavailableView(
                "Nada para revisar",
                systemImage: "checkmark.circle",
                description: Text("Los fragmentos con baja confianza o voces superpuestas aparecerán aquí."),
            )
        } else {
            List(model.reviewItems) { item in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("[\(item.segment.formattedTimestamp)] \(item.segment.speakerID)").font(.caption.bold())
                        Text(item.reason).font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button(item.manuallyAssignedToProfessor ? "Asignado al profesor ✓" : "Asignar al profesor") {
                            model.toggleReviewAssignment(item.id)
                        }
                        .controlSize(.small)
                    }
                    Text(item.segment.text).textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }
        }
    }
}
