import SwiftUI

struct ContentView: View {
    @Bindable var model: ClassScribeModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            captureConfiguration
            Divider()
            statusBar
            Divider()
            HSplitView {
                speakersPanel
                    .frame(minWidth: 245, idealWidth: 280, maxWidth: 330)
                transcriptPanel
                    .frame(minWidth: 700)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("ClassScribe", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("Aceptar") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 1) {
                Text("ClassScribe").font(.title2.bold())
                Text("Transcripción local de clases · sin nube")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Modo", selection: $model.mode) {
                ForEach(CaptureMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 310)
            .disabled(model.isRecording)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var captureConfiguration: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                TextField("Nombre de la materia", text: $model.subject)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 240)
                    .disabled(model.isRecording)

                if model.mode == .online {
                    Picker("Aplicación", selection: $model.selectedApplicationID) {
                        Text("Seleccionar aplicación…").tag(Int32?.none)
                        ForEach(model.capture.applications) { app in
                            Text(app.name).tag(Int32?.some(app.id))
                        }
                    }
                    .frame(minWidth: 280)
                    .disabled(model.isRecording)
                } else {
                    Picker("Micrófono", selection: $model.selectedMicrophoneID) {
                        Text("Seleccionar micrófono…").tag(String?.none)
                        ForEach(model.capture.microphones) { mic in
                            Text(mic.name).tag(String?.some(mic.id))
                        }
                    }
                    .frame(minWidth: 280)
                    .disabled(model.isRecording)
                }

                Button {
                    model.refreshSources()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Actualizar aplicaciones y micrófonos")
                .disabled(model.isRecording)
            }

            HStack(alignment: .top, spacing: 12) {
                TextField(
                    "Vocabulario técnico, separado por comas (Newton-Raphson, Runge-Kutta, PMBOK…)",
                    text: $model.technicalVocabulary,
                    axis: .vertical
                )
                .lineLimit(2 ... 3)
                .textFieldStyle(.roundedBorder)
                .disabled(model.isRecording)

                recordingControls
            }
        }
        .padding(14)
    }

    private var recordingControls: some View {
        HStack(spacing: 8) {
            if !model.isRecording {
                Button("Iniciar clase") { Task { await model.startClass() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canStart)
            } else {
                if model.isTranscriptionPaused {
                    Button("Reanudar transcripción") { model.resumeTranscription() }
                } else {
                    Button("Pausar transcripción") { model.pauseTranscription() }
                }
                Button("Detener clase", role: .destructive) { model.stopClass() }
            }
            if model.state == .finalTranscription || model.state == .diarizing {
                Button("Cancelar procesamiento", role: .cancel) { model.cancelFinalProcessing() }
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 18) {
            HStack(spacing: 7) {
                Circle()
                    .fill(model.isRecording ? .red : statusColor)
                    .frame(width: 10, height: 10)
                Text(model.isRecording ? "GRABANDO" : model.state.rawValue.uppercased())
                    .font(.caption.bold())
            }
            Label(Timecode.display(model.elapsed), systemImage: "timer")
                .monospacedDigit()
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                Gauge(value: max(-60, model.capture.levelDBFS), in: -60 ... 0) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .frame(width: 120)
                Text(String(format: "%.0f dB", model.capture.levelDBFS))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Label(String(format: "Demora %.1f s", model.transcriptionLatency), systemImage: "clock")
                .font(.caption)
            Text(model.statusDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            if model.currentFolder != nil {
                Button("Abrir carpeta") { model.openCurrentFolder() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private var statusColor: Color {
        switch model.state {
        case .complete: .green
        case .failed: .red
        case .cancelled: .orange
        case .ready: .secondary
        default: .blue
        }
    }

    private var speakersPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Hablantes detectados").font(.headline)
                Spacer()
                Text("\(model.speakers.count)").foregroundStyle(.secondary)
            }

            if model.speakers.isEmpty {
                ContentUnavailableView(
                    "Aún sin voces",
                    systemImage: "person.2.wave.2",
                    description: Text("Las etiquetas Persona 1, Persona 2… aparecerán al diarizar. Nunca se descarta el audio.")
                )
                .frame(maxHeight: 210)
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

            Button {
                model.calibrateProfessorVoice()
            } label: {
                Label(
                    model.isCalibrating ? "Calibrando… \(model.calibrationSecondsRemaining) s" : "Calibrar voz del profesor",
                    systemImage: "waveform.badge.mic"
                )
            }
            .disabled(!model.isRecording || model.isCalibrating)

            if let professor = model.professorSpeakerID {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Profesor: \(professor)", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.subheadline.bold()).foregroundStyle(.indigo)
                    if model.professorSelectionIsAutomatic {
                        Text("Selección automática y provisional; corrígela con un clic.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }

            Divider()
            Text("Historial de clases").font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.history) { item in
                        Button { model.openHistoryFolder(item) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.subject).font(.subheadline.bold()).lineLimit(1)
                                Text("\(item.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(Timecode.display(item.duration))")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("\(item.mode.rawValue) · \(item.source)")
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                Text("\(item.professorSpeakerID ?? "Profesor pendiente") · \(item.speakerCount) hablante(s) · \(item.state.rawValue)")
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                Text(item.folderPath)
                                    .font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
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
                Text("“\(sample)”").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack {
                Text("Confianza \(Int(speaker.confidence * 100)) %").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button(model.professorSpeakerID == speaker.id ? "Profesor ✓" : "Este es el profesor") {
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

    private var transcriptPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Transcripción", selection: $model.selectedTab) {
                    ForEach(TranscriptTab.allCases) { tab in
                        Text(tab.rawValue + (tab == .review && !model.reviewItems.isEmpty ? " (\(model.reviewItems.count))" : ""))
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 560)
                Spacer()
                Button("Copiar todo") { model.copyAll() }
                Button("Copiar para ChatGPT") { model.copyForChatGPT() }
                Menu("Exportar") {
                    ForEach(ExportKind.allCases) { kind in
                        Button(kind.rawValue) { model.export(kind) }
                    }
                }
            }
            .padding(12)

            Divider()

            if !model.finalReplacedLive {
                liveTranscript
            } else if model.selectedTab == .review {
                reviewPanel
            } else {
                TextEditor(text: editableText)
                    .font(.system(.body, design: .rounded))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor))
            }

            if model.finalReplacedLive {
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

    private var liveTranscript: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.stableLiveText.isEmpty ? "La transcripción aparecerá aquí mientras habla el profesor…" : model.stableLiveText)
                    .foregroundStyle(model.stableLiveText.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                if !model.provisionalLiveText.isEmpty {
                    Text(model.provisionalLiveText)
                        .italic()
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(18)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var editableText: Binding<String> {
        Binding(
            get: {
                switch model.selectedTab {
                case .professor:
                    return model.editedProfessorText.isEmpty
                        ? TranscriptExporter.plainText(model.professorSegments)
                        : model.editedProfessorText
                case .everyone:
                    return model.editedAllText.isEmpty
                        ? TranscriptExporter.plainText(model.allSegments)
                        : model.editedAllText
                case .review: return ""
                }
            },
            set: { newValue in
                if model.selectedTab == .professor { model.editedProfessorText = newValue }
                if model.selectedTab == .everyone { model.editedAllText = newValue }
            }
        )
    }

    private var reviewPanel: some View {
        Group {
            if model.reviewItems.isEmpty {
                ContentUnavailableView(
                    "Nada para revisar",
                    systemImage: "checkmark.circle",
                    description: Text("Los fragmentos con baja confianza o voces superpuestas aparecerán aquí.")
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
}
