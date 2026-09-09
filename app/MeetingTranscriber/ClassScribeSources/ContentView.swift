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
            ClassScribeLocalization.text(.guidanceSubject, language: .spanish)
        case .sourceRequired(.online):
            ClassScribeLocalization.text(.guidanceApplication, language: .spanish)
        case .sourceRequired(.inPerson):
            ClassScribeLocalization.text(.guidanceMicrophone, language: .spanish)
        }
    }

    var localizationKey: LocalizationKey? {
        switch self {
        case .ready: nil
        case .subjectRequired: .guidanceSubject
        case .sourceRequired(.online): .guidanceApplication
        case .sourceRequired(.inPerson): .guidanceMicrophone
        }
    }
}

struct LiveTranscriptFollowPresentation: Equatable {
    var message: String
    var actionTitle: String?
    var systemImage: String
    var messageKey: LocalizationKey
    var actionKey: LocalizationKey?

    static func resolve(
        isFollowing: Bool,
        isEditing: Bool,
        hasUnseenText: Bool,
    ) -> LiveTranscriptFollowPresentation {
        if isFollowing {
            return LiveTranscriptFollowPresentation(
                message: ClassScribeLocalization.text(.liveFollowing, language: .spanish),
                actionTitle: nil,
                systemImage: "arrow.down.to.line.compact",
                messageKey: .liveFollowing,
                actionKey: nil,
            )
        }
        if hasUnseenText {
            return LiveTranscriptFollowPresentation(
                message: ClassScribeLocalization.text(.liveNewText, language: .spanish),
                actionTitle: ClassScribeLocalization.text(.liveNewTextAction, language: .spanish),
                systemImage: "text.badge.plus",
                messageKey: .liveNewText,
                actionKey: .liveNewTextAction,
            )
        }
        return LiveTranscriptFollowPresentation(
            message: ClassScribeLocalization.text(
                isEditing ? .liveEditing : .livePaused,
                language: .spanish,
            ),
            actionTitle: ClassScribeLocalization.text(.liveFollowAction, language: .spanish),
            systemImage: isEditing ? "character.cursor.ibeam" : "pause.circle",
            messageKey: isEditing ? .liveEditing : .livePaused,
            actionKey: .liveFollowAction,
        )
    }
}

struct ContentView: View {
    @Bindable var model: ClassScribeModel
    @State private var showsTechnicalVocabulary = false
    @State private var systemOutputConsentPresentation = SystemOutputConsentPresentationState()
    @State private var liveEditorIsEditing = false
    @State private var followsLiveTranscript = true
    @State private var hasUnseenLiveTranscript = false
    @State private var editingSpeakerID: String?
    @State private var editingSpeakerName = ""

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
        .environment(\.locale, model.interfaceLocale)
        .alert(item: $systemOutputConsentPresentation.presentedRequest) { request in
            Alert(
                title: Text(model.localized(.consentTitle)),
                message: Text(model.localized(.consentBody)),
                primaryButton: .default(Text(model.localized(.consentConfirm))) {
                    Task { await model.confirmSystemOutputConsent(request) }
                },
                secondaryButton: .cancel(Text(model.localized(.consentCancel))) {
                    model.cancelSystemOutputConsent(request)
                },
            )
        }
        .onAppear {
            systemOutputConsentPresentation.synchronize(
                with: model.pendingSystemOutputConsent,
            )
        }
        .onChange(of: model.pendingSystemOutputConsent) { _, pending in
            systemOutputConsentPresentation.synchronize(with: pending)
        }
        .onDisappear {
            systemOutputConsentPresentation.presentedRequest = nil
            if let request = model.pendingSystemOutputConsent {
                model.cancelSystemOutputConsent(request)
            }
        }
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
                Text(model.localized(.headerSubtitle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .help(BuildIdentity.provenanceLabel)
            Spacer()
            Label(model.localized(.headerLocalProcessing), systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .trailing, spacing: 2) {
                Text(model.localized(.appLanguageLabel))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Picker(model.localized(.appLanguageLabel), selection: $model.interfaceLanguage) {
                    ForEach(InterfaceLanguage.allCases) { language in
                        Text(model.localizedInterfaceLanguageName(language)).tag(language)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityLabel(model.localized(.appLanguageLabel))
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var captureConfiguration: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.localized(.configTitle))
                .font(.headline)

            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.localized(.subjectLabel))
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    TextField(model.localized(.subjectPlaceholder), text: $model.subject)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.isSessionBusy)
                }
                .frame(minWidth: 210, idealWidth: 250)

                VStack(alignment: .leading, spacing: 5) {
                    Text(model.localized(.classTypeLabel))
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Picker(model.localized(.classTypeLabel), selection: $model.mode) {
                        ForEach(CaptureMode.allCases) { mode in
                            Text(model.localizedCaptureModeName(mode)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .disabled(model.isSessionBusy)
                }
                .frame(width: 240)

                VStack(alignment: .leading, spacing: 5) {
                    Text(model.localized(.transcriptionLanguageLabel))
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Picker(model.localized(.transcriptionLanguageLabel), selection: $model.language) {
                        ForEach(TranscriptionLanguage.allCases) { language in
                            Text(model.localizedTranscriptionLanguageName(language)).tag(language)
                        }
                    }
                    .labelsHidden()
                    .disabled(model.isSessionBusy)
                }
                .frame(width: 105)

                VStack(alignment: .leading, spacing: 5) {
                    if model.mode == .online {
                        Text(model.localized(.onlineSourceLabel))
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Picker(model.localized(.onlineSourceLabel), selection: $model.onlineCaptureSource) {
                            ForEach(OnlineCaptureSource.allCases) { source in
                                Text(model.localizedOnlineSourceName(source)).tag(source)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .accessibilityLabel(model.localized(.audioSourceOnlineAccessibility))
                        if model.onlineCaptureSource == .systemOutput {
                            Text(model.localized(.systemOutputHint))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityLabel(model.localized(.systemOutputHint))
                        } else {
                            HStack(spacing: 6) {
                                sourcePicker
                                Button {
                                    model.refreshSources()
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .help(model.localized(.refreshAudioSources))
                                .accessibilityLabel(model.localized(.refreshAudioSources))
                            }
                        }
                    } else {
                        Text(model.localized(.microphonePickerLabel))
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            sourcePicker
                            Button {
                                model.refreshSources()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .help(model.localized(.refreshAudioSources))
                            .accessibilityLabel(model.localized(.refreshAudioSources))
                        }
                    }
                }
                .disabled(model.isSessionBusy)
                .frame(minWidth: 250, idealWidth: 300)

                Spacer(minLength: 0)
                primaryCaptureControls
            }

            DisclosureGroup(isExpanded: $showsTechnicalVocabulary) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.localized(.technicalVocabularyHelp))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(
                        model.localized(.technicalVocabularyPlaceholder),
                        text: $model.technicalVocabulary,
                    )
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isSessionBusy)
                }
                .padding(.top, 7)
            } label: {
                Label(model.localized(.technicalVocabularyLabel), systemImage: "text.badge.plus")
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
            Picker(model.localized(.applicationPickerLabel), selection: $model.selectedApplicationIdentityID) {
                Text(model.localized(.selectApplication)).tag(String?.none)
                ForEach(model.capture.applications) { app in
                    Text(app.name).tag(String?.some(app.logicalIdentityID))
                }
            }
            .labelsHidden()
            .frame(minWidth: 220)
        } else {
            Picker(model.localized(.microphonePickerLabel), selection: $model.selectedMicrophoneID) {
                Text(model.localized(.selectMicrophone)).tag(String?.none)
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
            isStarting: model.isStarting,
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
                ? model.onlineCaptureSource == .systemOutput || model.selectedApplication != nil
                : model.selectedMicrophone != nil,
        )
    }

    @ViewBuilder
    private var primaryCaptureControls: some View {
        VStack(alignment: .trailing, spacing: 5) {
            switch primaryControlState {
            case .stopping:
                progressLabel(model.localized(.statusSaving))
            case .starting:
                HStack(spacing: 8) {
                    progressLabel(
                        model.isPreparingTranscription
                            ? model.localized(.statusPreparingTranscription)
                            : model.localized(.statusConnectingAudio),
                    )
                    Button(model.localized(.buttonCancel), role: .cancel) {
                        model.cancelStart()
                    }
                }
            case let .recording(paused):
                HStack(spacing: 8) {
                    Button {
                        paused ? model.resumeTranscription() : model.pauseTranscription()
                    } label: {
                        Label(
                            paused
                                ? model.localized(.buttonResumeText)
                                : model.localized(.buttonPauseText),
                            systemImage: paused ? "play.fill" : "pause.fill",
                        )
                    }
                    Button(role: .destructive) {
                        Task { await model.stopClass() }
                    } label: {
                        Label(model.localized(.buttonFinish), systemImage: "stop.fill")
                    }
                }
            case .processing:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    if model.isRetrying || model.state == .finalTranscription || model.state == .diarizing {
                        Button(model.localized(.buttonCancelProcessing), role: .cancel) {
                            model.cancelFinalProcessing()
                        }
                    }
                }
            case .ready:
                Button {
                    Task { await model.startClass() }
                } label: {
                    Label(model.localized(.buttonStartRecording), systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canStart)
                if !model.canStart, let key = startGuidance.localizationKey {
                    Text(model.localized(key))
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
                Text(model.localized(.audioLevel))
                    }
                    .labelsHidden()
                    .gaugeStyle(.accessoryLinearCapacity)
                    .frame(width: 92)
                    .accessibilityLabel(model.localized(.audioLevel))
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
                    Label(model.localized(.buttonRetryProcessing), systemImage: "arrow.clockwise")
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
            return model.isTranscriptionPaused
                ? model.localized(.statusRecordingPaused)
                : model.localized(.statusRecordingAndTranscribing)
        }
        return model.localizedProcessingStateName(model.state)
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
                Label(model.localized(.voicesTitle), systemImage: "person.2.wave.2")
                    .font(.headline)
                Spacer()
                if model.hasSpeakerCorrections {
                    Label(model.localized(.speakerManualCorrection), systemImage: "pencil.and.outline")
                        .font(.caption2)
                        .foregroundStyle(.indigo)
                        .help(model.localized(.speakerManualCorrection))
                }
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
                    Text(model.localized(.voicesEmpty))
                        .font(.subheadline.bold())
                    Text(model.localized(.voicesDescription))
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
                            ? model.localized(
                                .calibrationInProgress,
                                arguments: ["seconds": String(model.calibrationSecondsRemaining)],
                            )
                            : model.localized(.calibrationButton),
                        systemImage: "waveform.badge.mic",
                    )
                }
                .disabled(model.isCalibrating || model.isStopping)
                .help(model.localized(.calibrationHelp))
            }

            if let professor = model.professorSpeakerID {
                VStack(alignment: .leading, spacing: 3) {
                    Label(
                        "\(model.localized(.professorLabel)): \(model.localizedSpeakerName(id: professor))",
                        systemImage: "person.crop.circle.badge.checkmark",
                    )
                        .font(.subheadline.bold())
                        .foregroundStyle(.indigo)
                    if model.professorSelectionIsAutomatic {
                        Text(model.localized(.professorAutomatic))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()
            HStack {
                Label(model.localized(.historyTitle), systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                if !model.history.isEmpty {
                    Text("\(model.history.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if model.history.isEmpty {
                Text(model.localized(.historyEmpty))
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
                                            "\(model.localizedDate(item.startedAt, dateStyle: .short)) · "
                                                + Timecode.display(item.duration),
                                        )
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        if item.isRecoverable {
                                            Text(model.localized(.historyRecoverable))
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
                if editingSpeakerID == speaker.id {
                    TextField(
                        model.localized(.speakerRenamePlaceholder),
                        text: $editingSpeakerName,
                    )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveSpeakerName(speaker) }
                } else {
                    Text(model.localizedSpeakerName(speaker)).font(.subheadline.bold())
                }
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
                if editingSpeakerID == speaker.id {
                    Button(model.localized(.speakerSaveName)) {
                        saveSpeakerName(speaker)
                    }
                    .controlSize(.mini)
                    Button(model.localized(.buttonCancel)) {
                        editingSpeakerID = nil
                    }
                    .controlSize(.mini)
                } else {
                    Menu {
                        Button {
                            editingSpeakerID = speaker.id
                            editingSpeakerName = speaker.displayName
                        } label: {
                            Label(model.localized(.speakerRename), systemImage: "pencil")
                        }
                        ForEach(model.speakers.filter { $0.id != speaker.id }) { other in
                            Button {
                                model.mergeSpeakers(sourceID: other.id, targetID: speaker.id)
                            } label: {
                                Label(
                                    "\(model.localized(.speakerMergeWith)) \(model.localizedSpeakerName(other))",
                                    systemImage: "arrow.triangle.merge",
                                )
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.mini)
                    .help(model.localized(.speakerManagement))
                }
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

    private func saveSpeakerName(_ speaker: SpeakerRecord) {
        model.renameSpeaker(speaker.id, displayName: editingSpeakerName)
        editingSpeakerID = nil
    }

    private func professorButtonTitle(for speaker: SpeakerRecord) -> String {
        guard model.professorSpeakerID == speaker.id else { return model.localized(.professorChoose) }
        return model.professorSelectionIsAutomatic
            ? model.localized(.professorConfirm)
            : model.localized(.professorConfirmed)
    }

    private var transcriptPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if model.finalReplacedLive {
                    Picker(model.localized(.transcriptPickerLabel), selection: $model.selectedTab) {
                        ForEach(model.availableTranscriptTabs) { tab in
                            Text(
                                model.localizedTranscriptTabName(tab)
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
                        model.isRecording
                            ? model.localized(.transcriptLiveTitle)
                            : model.localized(.transcriptTitle),
                        systemImage: "text.alignleft",
                    )
                    .font(.headline)
                }
                if liveFollowPresentation.actionKey != nil, model.isRecording {
                    Button {
                        resumeLiveTranscriptFollowing()
                    } label: {
                        Label(
                            model.localized(liveFollowPresentation.actionKey!),
                            systemImage: "arrow.down.to.line.compact",
                        )
                    }
                    .controlSize(.small)
                    .help(model.localized(.liveFollowAction))
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
                    model.localized(.transcriptEmptyTitle),
                    systemImage: "text.quote",
                    description: Text(model.localized(.transcriptEmptyDescription)),
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
                    Text(model.localized(liveFollowPresentation.messageKey))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(9)
                .background((followsLiveTranscript ? Color.indigo : Color.orange).opacity(0.06))
            } else if model.finalReplacedLive, model.selectedTab == .liveEdit {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(model.localized(.liveCorrectionsKept))
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
                    Text(model.localized(.liveFinalReplaced))
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
                Label(model.localized(.copyTranscript), systemImage: "doc.on.doc")
            }
            .disabled(!model.hasCopyableTranscript)

            Button {
                model.copyForChatGPT()
            } label: {
                Label(model.localized(.copyForChatGPT), systemImage: "text.badge.plus")
            }
            .disabled(!model.hasCopyableTranscript)

            Divider()

            Button {
                model.openCurrentTXT()
            } label: {
                Label(model.localized(.openTextFile), systemImage: "doc.text")
            }
            .disabled(!model.canOpenTXT)

            Button {
                model.openCurrentFolder()
            } label: {
                Label(model.localized(.showFolder), systemImage: "folder")
            }
            .disabled(model.currentFolder == nil)

            Divider()

            ForEach(ExportKind.allCases) { kind in
                Button {
                    model.export(kind)
                } label: {
                    Label(model.localizedExportName(kind), systemImage: "square.and.arrow.up")
                }
                .disabled(!model.hasCopyableTranscript)
            }
        } label: {
            Label(model.localized(.actions), systemImage: "ellipsis.circle")
        }
    }

    private var liveTranscript: some View {
        ZStack(alignment: .topLeading) {
            LiveTranscriptEditor(
                text: liveEditableText,
                isEditing: $liveEditorIsEditing,
                isFollowing: $followsLiveTranscript,
                accessibilityLabel: model.localized(.liveEditing),
                accessibilityHelp: model.localized(.liveAccessibilityHelp),
                onFinalize: { _ = model.flushEditedLiveText() },
            )
            if model.liveEditableText.isEmpty {
                Text(model.localized(.livePlaceholder))
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
                            ? (model.editedAllText ?? TranscriptExporter.plainText(
                                model.allSegments,
                                speakerNames: model.speakerDisplayNames,
                            ))
                            : TranscriptExporter.plainText(
                                model.professorSegments,
                                speakerNames: model.speakerDisplayNames,
                            ))
                case .everyone:
                    return model.editedAllText ?? TranscriptExporter.plainText(
                        model.allSegments,
                        speakerNames: model.speakerDisplayNames,
                    )
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
            Button(model.localized(.hide)) { model.errorMessage = nil }
                .controlSize(.small)
            if model.canSelectSystemOutputAfterApplicationFailure {
                Button(model.localized(.consentConfirm)) {
                    model.selectSystemOutputAfterApplicationFailure()
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }

    @ViewBuilder
    private var reviewPanel: some View {
        if model.reviewItems.isEmpty {
            ContentUnavailableView(
                model.localized(.reviewEmptyTitle),
                systemImage: "checkmark.circle",
                description: Text(model.localized(.reviewEmptyDescription)),
            )
        } else {
            List(model.reviewItems) { item in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("[\(item.segment.formattedTimestamp)] \(model.localizedSpeakerName(id: item.segment.speakerID))")
                            .font(.caption.bold())
                        Text(model.localizedReviewReason(item.reason))
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button(
                            item.manuallyAssignedToProfessor
                                ? model.localized(.reviewAssigned)
                                : model.localized(.reviewAssign),
                        ) {
                            model.toggleReviewAssignment(item.id)
                        }
                        .controlSize(.small)
                    }
                    HStack(spacing: 6) {
                        Picker(
                            model.localized(.speakerReassignTarget),
                            selection: Binding(
                                get: { model.reassignmentTarget(for: item.segment.id) },
                                set: { model.setReassignmentTarget($0, for: item.segment.id) },
                            ),
                        ) {
                            ForEach(model.speakers) { speaker in
                                Text(model.localizedSpeakerName(speaker)).tag(speaker.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 180)
                        Button(model.localized(.speakerReassign)) {
                            model.reassignSegment(
                                item.segment.id,
                                to: model.reassignmentTarget(for: item.segment.id),
                            )
                        }
                        .controlSize(.small)
                        if model.canSplitSegment(item.segment.id) {
                            Menu {
                                ForEach(model.splitBoundaries(for: item.segment.id)) { boundary in
                                    Button(model.localized(
                                        .speakerSplitAfterWord,
                                        arguments: ["word": boundary.word],
                                    )) {
                                        model.splitSegment(
                                            item.segment.id,
                                            afterWordIndex: boundary.afterWordIndex,
                                        )
                                    }
                                }
                            } label: {
                                Label(model.localized(.speakerSplit), systemImage: "scissors")
                            }
                            .controlSize(.small)
                        }
                    }
                    Text(item.segment.text).textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }
        }
    }
}

/// Presentation-only state for the consent alert. The domain request remains
/// owned exclusively by `ClassScribeModel`, so SwiftUI may dismiss this copy
/// without erasing the request that the affirmative action must consume.
struct SystemOutputConsentPresentationState: Equatable {
    var presentedRequest: SystemOutputConsentRequest? = nil

    mutating func synchronize(with domainRequest: SystemOutputConsentRequest?) {
        presentedRequest = domainRequest
    }
}
