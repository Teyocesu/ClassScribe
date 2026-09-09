using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Windows;
using ClassScribe.Core;

namespace ClassScribe.Windows;

internal sealed class MainViewModel : ObservableObject, IAsyncDisposable
{
    private const long MaximumReadableDocumentBytes = 64 * 1_024 * 1_024;
    private const double QualityCheckpointSeconds = 60;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    private readonly SessionStore sessionStore;
    private readonly AppLocalization localization;
    private readonly LocalModelProvisioner modelProvisioner = new();
    private readonly WindowsAudioCapture audioCapture;
    private readonly Func<bool> systemOutputConsentPrompt;
    private readonly WhisperTranscriber transcriber;
    private readonly List<TranscriptSegment> segments = [];
    private readonly List<TranscriptSegment> qualitySegments = [];
    private readonly Func<IProgress<ModelDownloadProgress>?, CancellationToken, Task> prepareTranscription;
    private CancellationTokenSource? liveCancellation;
    private CancellationTokenSource? timerCancellation;
    private CancellationTokenSource? processingCancellation;
    private TaskCompletionSource? activeOperation;
    private Task? liveTask;
    private Task? timerTask;
    private CaptureModeChoice selectedMode;
    private LanguageChoice selectedLanguage;
    private OnlineCaptureSourceChoice selectedOnlineSource;
    private AudioSourceOption? selectedSource;
    private SystemOutputConsentRequest? pendingSystemOutputConsent;
    private CaptureRecoverySuggestion? captureRecoverySuggestion;
    private CaptureFault? activeCaptureFault;
    private HistoryRow? selectedHistory;
    private SpeakerChoice? selectedProfessor;
    private SpeakerChoice? selectedSpeaker;
    private SpeakerChoice? selectedMergeTarget;
    private SpeakerChoice? selectedCorrectionSpeaker;
    private ReviewRow? selectedReviewRow;
    private SplitBoundaryChoice? selectedSplitBoundary;
    private string speakerNameDraft = string.Empty;
    private ClassMetadata? currentMetadata;
    private string? currentFolder;
    private string subject = string.Empty;
    private string vocabulary = string.Empty;
    private string liveText = string.Empty;
    private string allText = string.Empty;
    private string professorText = string.Empty;
    private string automaticLiveText = string.Empty;
    private LocalizedMessage statusMessage = LocalizedMessage.Keyed("StatusReady");
    private LocalizedMessage? warningMessage;
    private string elapsedText = "00:00";
    private double audioLevel;
    private CaptureSignalState captureSignalState = CaptureSignalState.AwaitingCallbacks;
    private CaptureSignalState? lastPresentedCaptureSignalState;
    private double modelProgress;
    private bool isRecording;
    private bool isBusy;
    private bool isPaused;
    private bool liveWasEdited;
    private bool qualityCoverageHasGap;
    private bool isStopping;
    private bool settingLiveProgrammatically;
    private bool disposed;
    private int finalProcessingInvocationCountForTest;
    private long attemptGeneration;
    private double liveTranscribedThroughSeconds;
    private double qualityTranscribedThroughSeconds;
    private SessionAttemptID? activeAttempt;
    private SessionAttemptCallbackLease? captureCallbackLease;
    private Action<SessionAttemptID, double>? captureLevelHandler;
    private Action<SessionAttemptID, CaptureSignalHealthSnapshot>? captureSignalHealthHandler;
    private Action<SessionAttemptID, CaptureFault>? captureFaultHandler;
    private ASRTranscriptReference? asrOriginalReference;
    private DiarizationProposal? activeDiarizationProposal;
    private HumanCorrectionOverlay? activeHumanCorrectionOverlay;

    public MainViewModel(
        SessionStore? sessionStore = null,
        WindowsAudioCapture? audioCapture = null,
        Func<bool>? systemOutputConsentPrompt = null,
        Func<IProgress<ModelDownloadProgress>?, CancellationToken, Task>? prepareTranscription = null,
        AppLocalization? localization = null)
    {
        this.sessionStore = sessionStore ?? new SessionStore();
        this.localization = localization ?? AppLocalization.Instance;
        this.localization.PropertyChanged += Localization_PropertyChanged;
        this.audioCapture = audioCapture ?? new WindowsAudioCapture();
        this.systemOutputConsentPrompt = systemOutputConsentPrompt ?? (() => false);
        CaptureModes =
        [
            new CaptureModeChoice(CaptureMode.Online, this.localization["CaptureModeOnline"]),
            new CaptureModeChoice(CaptureMode.InPerson, this.localization["CaptureModeInPerson"]),
        ];
        OnlineSourceChoices =
        [
            new OnlineCaptureSourceChoice(OnlineCaptureSource.Application, this.localization["OnlineSourceApplication"]),
            new OnlineCaptureSourceChoice(OnlineCaptureSource.SystemOutput, this.localization["OnlineSourceSystemOutput"]),
        ];
        Languages =
        [
            new LanguageChoice("es", this.localization["LanguageSpanish"]),
            new LanguageChoice("en", this.localization["LanguageEnglish"]),
            new LanguageChoice("fr", this.localization["LanguageFrench"]),
        ];
        InterfaceLanguages = this.localization.InterfaceLanguages;
        selectedMode = CaptureModes[0];
        selectedOnlineSource = OnlineSourceChoices[0];
        selectedLanguage = Languages[0];
        transcriber = new WhisperTranscriber(modelProvisioner);
        this.prepareTranscription = prepareTranscription ?? transcriber.PrepareAsync;
    }

    public IReadOnlyList<CaptureModeChoice> CaptureModes { get; }

    public IReadOnlyList<OnlineCaptureSourceChoice> OnlineSourceChoices { get; }

    public IReadOnlyList<LanguageChoice> Languages { get; }

    public ObservableCollection<InterfaceLanguageOption> InterfaceLanguages { get; }

    public ObservableCollection<AudioSourceOption> Sources { get; } = [];

    public ObservableCollection<HistoryRow> History { get; } = [];

    public ObservableCollection<SpeakerChoice> Speakers { get; } = [];

    public ObservableCollection<ReviewRow> ReviewRows { get; } = [];

    public ObservableCollection<SplitBoundaryChoice> SplitBoundaries { get; } = [];

    public CaptureModeChoice SelectedMode
    {
        get => selectedMode;
        set
        {
            if (SetProperty(ref selectedMode, value))
            {
                InvalidatePendingSystemOutputConsent();
                captureRecoverySuggestion = null;
                OnPropertyChanged(nameof(ShowSystemOutputRecovery));
                SelectedSource = null;
                if (value.Value != CaptureMode.Online)
                {
                    SelectedOnlineSource = OnlineSourceChoices[0];
                }
                NotifySourcePresentation();
                NotifyAvailability();
            }
        }
    }

    public OnlineCaptureSourceChoice SelectedOnlineSource
    {
        get => selectedOnlineSource;
        set
        {
            if (SetProperty(ref selectedOnlineSource, value))
            {
                InvalidatePendingSystemOutputConsent();
                captureRecoverySuggestion = null;
                OnPropertyChanged(nameof(ShowSystemOutputRecovery));
                NotifySourcePresentation();
                NotifyAvailability();
            }
        }
    }

    public LanguageChoice SelectedLanguage
    {
        get => selectedLanguage;
        set => SetProperty(ref selectedLanguage, value);
    }

    public AudioSourceOption? SelectedSource
    {
        get => selectedSource;
        set
        {
            if (SetProperty(ref selectedSource, value))
            {
                InvalidatePendingSystemOutputConsent();
                NotifyAvailability();
            }
        }
    }

    public HistoryRow? SelectedHistory
    {
        get => selectedHistory;
        set => SetProperty(ref selectedHistory, value);
    }

    public SpeakerChoice? SelectedProfessor
    {
        get => selectedProfessor;
        set => SetProperty(ref selectedProfessor, value);
    }

    public SpeakerChoice? SelectedSpeaker
    {
        get => selectedSpeaker;
        set
        {
            if (SetProperty(ref selectedSpeaker, value))
            {
                SpeakerNameDraft = value?.Model.DisplayName ?? string.Empty;
                OnPropertyChanged(nameof(MergeTargets));
            }
        }
    }

    public SpeakerChoice? SelectedMergeTarget
    {
        get => selectedMergeTarget;
        set => SetProperty(ref selectedMergeTarget, value);
    }

    public SpeakerChoice? SelectedCorrectionSpeaker
    {
        get => selectedCorrectionSpeaker;
        set => SetProperty(ref selectedCorrectionSpeaker, value);
    }

    public ReviewRow? SelectedReviewRow
    {
        get => selectedReviewRow;
        set
        {
            if (SetProperty(ref selectedReviewRow, value))
            {
                var currentID = value?.Item.Segment.SpeakerID;
                SelectedCorrectionSpeaker = Speakers.FirstOrDefault(speaker =>
                    speaker.Id != currentID) ?? Speakers.FirstOrDefault();
                RefreshSplitBoundaries();
                NotifyCorrectionAvailability();
            }
        }
    }

    public SplitBoundaryChoice? SelectedSplitBoundary
    {
        get => selectedSplitBoundary;
        set => SetProperty(ref selectedSplitBoundary, value);
    }

    public string SpeakerNameDraft
    {
        get => speakerNameDraft;
        set => SetProperty(ref speakerNameDraft, value);
    }

    public IReadOnlyList<SpeakerChoice> MergeTargets => Speakers
        .Where(speaker => selectedSpeaker is null || speaker.Id != selectedSpeaker.Id)
        .ToArray();

    public bool HasSpeakerCorrections => activeHumanCorrectionOverlay?.Operations.Count > 0;

    public bool CanEditSpeakers => !IsBusy && !IsRecording && segments.Count > 0;

    public bool CanSplitSelectedReview => CanEditSpeakers
        && SelectedReviewRow is not null
        && SelectedSplitBoundary is not null
        && SpeakerCorrectionProjection.CanSplit(SelectedReviewRow.Item.Segment);

    public string Subject
    {
        get => subject;
        set
        {
            if (SetProperty(ref subject, value))
            {
                InvalidatePendingSystemOutputConsent();
                NotifyAvailability();
            }
        }
    }

    public string Vocabulary
    {
        get => vocabulary;
        set => SetProperty(ref vocabulary, value);
    }

    public string LiveText
    {
        get => liveText;
        set
        {
            if (SetProperty(ref liveText, value)
                && IsRecording
                && !settingLiveProgrammatically)
            {
                liveWasEdited = true;
            }
        }
    }

    public string AllText
    {
        get => allText;
        set => SetProperty(ref allText, value);
    }

    public string ProfessorText
    {
        get => professorText;
        set => SetProperty(ref professorText, value);
    }

    public string StatusText
    {
        get => localization.Resolve(statusMessage);
        private set
        {
            if (!string.Equals(StatusText, value, StringComparison.Ordinal))
            {
                statusMessage = LocalizedMessage.Raw(value);
                OnPropertyChanged();
            }
        }
    }

    public string WarningText
    {
        get => warningMessage is null ? string.Empty : localization.Resolve(warningMessage);
        private set
        {
            if (!string.Equals(WarningText, value, StringComparison.Ordinal))
            {
                warningMessage = string.IsNullOrEmpty(value) ? null : LocalizedMessage.Raw(value);
                OnPropertyChanged();
                OnPropertyChanged(nameof(HasWarning));
            }
        }
    }

    public string InterfaceLanguageCode
    {
        get => localization.InterfaceLanguageCode;
        set => localization.Select(value);
    }

    public bool HasWarning => !string.IsNullOrWhiteSpace(WarningText);

    public bool IsOnline => SelectedMode.Value == CaptureMode.Online;

    public bool IsInPerson => SelectedMode.Value == CaptureMode.InPerson;

    public bool IsApplicationSource => IsOnline
        && SelectedOnlineSource.Value == OnlineCaptureSource.Application;

    public bool IsSystemOutputSource => IsOnline
        && SelectedOnlineSource.Value == OnlineCaptureSource.SystemOutput;

    public bool ShowSystemOutputRecovery => captureRecoverySuggestion == CaptureRecoverySuggestion.SystemOutput
        && IsApplicationSource
        && !IsRecording
        && !IsBusy;

    public SystemOutputConsentRequest? PendingSystemOutputConsent => pendingSystemOutputConsent;

    public string ElapsedText
    {
        get => elapsedText;
        private set => SetProperty(ref elapsedText, value);
    }

    public double AudioLevel
    {
        get => audioLevel;
        private set => SetProperty(ref audioLevel, value);
    }

    public CaptureSignalState SignalState
    {
        get => captureSignalState;
        private set => SetProperty(ref captureSignalState, value);
    }

    public double ModelProgress
    {
        get => modelProgress;
        private set => SetProperty(ref modelProgress, value);
    }

    public bool IsRecording
    {
        get => isRecording;
        private set
        {
            if (SetProperty(ref isRecording, value))
            {
                NotifyAvailability();
            }
        }
    }

    public bool IsBusy
    {
        get => isBusy;
        private set
        {
            if (SetProperty(ref isBusy, value))
            {
                NotifyAvailability();
            }
        }
    }

    public bool IsPaused
    {
        get => isPaused;
        private set
        {
            if (SetProperty(ref isPaused, value))
            {
                OnPropertyChanged(nameof(PauseButtonText));
            }
        }
    }

    public string PauseButtonText => IsPaused
        ? localization["ResumeText"]
        : localization["PauseText"];

    public bool CanStart => !IsBusy
        && !IsRecording
        && pendingSystemOutputConsent is null
        && !string.IsNullOrWhiteSpace(Subject)
        && (IsSystemOutputSource
            || (IsApplicationSource && SelectedSource?.Kind == AudioSourceKind.Process)
            || (IsInPerson && SelectedSource?.Kind == AudioSourceKind.Microphone));

    public bool CanStop => IsRecording && !IsBusy;

    public bool CanPause => IsRecording && !IsBusy;

    public bool CanCancel => IsBusy && processingCancellation is not null;

    public bool HasCurrentSession => currentFolder is not null;

    public string CurrentFolderLabel => currentFolder is null
        ? localization["NoSession"]
        : Path.GetFileName(currentFolder);

    public bool CanReprocess => !IsBusy
        && !IsRecording
        && currentFolder is not null
        && (File.Exists(Path.Combine(currentFolder, "source.wav"))
            || File.Exists(Path.Combine(currentFolder, "source.raw"))
            || (File.Exists(Path.Combine(currentFolder, "master.raw"))
                && File.Exists(Path.Combine(currentFolder, "audio-manifest.json"))));

    public async Task InitializeAsync()
    {
        await RefreshHistoryAsync().ConfigureAwait(true);
        await RefreshSourcesAsync().ConfigureAwait(true);
    }

    public async Task RefreshSourcesAsync()
    {
        if (pendingSystemOutputConsent is not null)
        {
            InvalidatePendingSystemOutputConsent();
            return;
        }

        if (IsRecording || IsBusy)
        {
            return;
        }

        var mode = SelectedMode.Value;
        if (mode == CaptureMode.Online
            && SelectedOnlineSource.Value == OnlineCaptureSource.SystemOutput)
        {
            WarningText = string.Empty;
            SetStatus("StatusComputerAudioReady");
            NotifyAvailability();
            return;
        }

        SetStatus(mode == CaptureMode.Online
            ? "StatusSearchingApplications"
            : "StatusSearchingMicrophones");
        WarningText = string.Empty;
        try
        {
            var previousSourceID = SelectedSource?.Id;
            var found = await Task.Run(() => mode == CaptureMode.Online
                    ? WindowsAudioCapture.EnumerateApplications()
                    : WindowsAudioCapture.EnumerateMicrophones())
                .ConfigureAwait(true);
            Sources.Clear();
            foreach (var source in found)
            {
                Sources.Add(source);
            }

            SelectedSource = Sources.FirstOrDefault(source => source.Id == previousSourceID)
                ?? Sources.FirstOrDefault();
            SetStatus(Sources.Count == 0
                ? mode == CaptureMode.Online
                    ? "StatusNoApplications"
                    : "StatusNoMicrophones"
                : "StatusSourcesReady");
        }
        catch (Exception error) when (error is InvalidOperationException
                                           or System.ComponentModel.Win32Exception
                                           or UnauthorizedAccessException)
        {
            Sources.Clear();
            SelectedSource = null;
            SetWarning("WarningSourceRead", error.Message);
            SetStatus("StatusPermission");
        }
    }

    public async Task StartAsync()
    {
        if (pendingSystemOutputConsent is not null)
        {
            InvalidatePendingSystemOutputConsent();
            return;
        }

        if (!CanStart)
        {
            SetWarning("StatusCompleteSubjectSource");
            return;
        }

        var mode = SelectedMode.Value;
        var onlineSource = SelectedOnlineSource.Value;
        var captureScope = mode == CaptureMode.Online
            ? onlineSource == OnlineCaptureSource.SystemOutput
                ? CaptureScope.SystemOutput
                : CaptureScope.Application
            : CaptureScope.Microphone;
        var source = captureScope == CaptureScope.SystemOutput
            ? new AudioSourceOption(AudioSourceKind.SystemOutput, "system-output", localization["OnlineSourceSystemOutput"])
            : SelectedSource;
        if (source is null)
        {
            SetWarning("StatusCompleteSubjectSource");
            return;
        }

        var subjectSnapshot = Subject.Trim();
        var vocabularySnapshot = Vocabulary.Trim();
        var languageSnapshot = SelectedLanguage.Code;
        var attempt = BeginAttempt(Guid.NewGuid());
        if (captureScope == CaptureScope.SystemOutput)
        {
            var request = new SystemOutputConsentRequest(
                Guid.NewGuid(),
                attempt,
                subjectSnapshot);
            pendingSystemOutputConsent = request;
            NotifyAvailability();
            bool accepted;
            try
            {
                accepted = systemOutputConsentPrompt();
            }
            catch
            {
                InvalidatePendingSystemOutputConsent();
                throw;
            }
            if (pendingSystemOutputConsent != request)
            {
                return;
            }

            pendingSystemOutputConsent = null;
            OnPropertyChanged(nameof(PendingSystemOutputConsent));
            NotifyAvailability();
            if (!accepted)
            {
                InvalidateAttempt(attempt);
                SetStatus("StatusComputerAudioCancelled");
                return;
            }

            if (!IsCurrent(attempt)
                || SelectedMode.Value != mode
                || SelectedOnlineSource.Value != onlineSource
                || Subject.Trim() != subjectSnapshot)
            {
                InvalidateAttempt(attempt);
                return;
            }

            var authorization = audioCapture.IssueSystemOutputAuthorizationAfterExplicitUserConsent(attempt);
            await StartAttemptAsync(
                    source,
                    attempt,
                    mode,
                    captureScope,
                    subjectSnapshot,
                    vocabularySnapshot,
                    languageSnapshot,
                    authorization)
                .ConfigureAwait(true);
            return;
        }

        await StartAttemptAsync(
                source,
                attempt,
                mode,
                captureScope,
                subjectSnapshot,
                vocabularySnapshot,
                languageSnapshot,
                systemOutputAuthorization: null)
            .ConfigureAwait(true);
    }

    private async Task StartAttemptAsync(
        AudioSourceOption source,
        SessionAttemptID attempt,
        CaptureMode mode,
        CaptureScope captureScope,
        string subjectSnapshot,
        string vocabularySnapshot,
        string languageSnapshot,
        SystemOutputCaptureAuthorization? systemOutputAuthorization)
    {
        var operation = BeginOperation();
        IsBusy = true;
        WarningText = string.Empty;
        captureRecoverySuggestion = null;
        OnPropertyChanged(nameof(ShowSystemOutputRecovery));
        ModelProgress = 0;
        segments.Clear();
        qualitySegments.Clear();
        Speakers.Clear();
        ReviewRows.Clear();
        SelectedProfessor = null;
        SelectedSpeaker = null;
        SelectedMergeTarget = null;
        SelectedCorrectionSpeaker = null;
        SelectedReviewRow = null;
        SplitBoundaries.Clear();
        SelectedSplitBoundary = null;
        automaticLiveText = string.Empty;
        liveWasEdited = false;
        qualityCoverageHasGap = false;
        liveTranscribedThroughSeconds = 0;
        qualityTranscribedThroughSeconds = 0;
        SetLiveProgrammatically(string.Empty);
        AllText = string.Empty;
        ProfessorText = string.Empty;
        processingCancellation = new CancellationTokenSource();
        NotifyAvailability();
        var cancellationToken = processingCancellation.Token;
        var startedAt = DateTimeOffset.Now;
        var sessionID = attempt.SessionID;
        SignalState = CaptureSignalState.AwaitingCallbacks;
        lastPresentedCaptureSignalState = null;
        RegisterCaptureCallbacks(attempt);
        var captureStarted = false;
        var captureStartInvoked = false;
        asrOriginalReference = null;
        activeDiarizationProposal = null;
        activeHumanCorrectionOverlay = null;

        try
        {
            SetStatus("StatusPreparingBeforeRecording");
            var modelProgress = new Progress<ModelDownloadProgress>(
                value => UpdateModelProgress(value, attempt));
            await prepareTranscription(modelProgress, cancellationToken).ConfigureAwait(true);
            if (!IsCurrent(attempt))
            {
                return;
            }

            SetStatus("StatusModelReady");
            currentFolder = sessionStore.CreateFolder(subjectSnapshot, startedAt);
            currentMetadata = new ClassMetadata
            {
                Id = sessionID,
                Subject = subjectSnapshot,
                StartedAt = startedAt,
                Mode = mode,
                CaptureScope = captureScope,
                Source = source.DisplayName,
                TechnicalVocabulary = vocabularySnapshot,
                Language = languageSnapshot,
                AudioFormat = captureScope == CaptureScope.Microphone
                    ? PcmWaveFile.AudioFormatName
                    : PcmWaveFile.MasterAudioFormatName,
                FormatVersion = captureScope == CaptureScope.Microphone ? 1 : 2,
                State = ProcessingState.StartingCapture,
                SessionPhase = ClassScribe.Core.SessionPhase.Starting,
                CapturePhase = ClassScribe.Core.CapturePhase.Connecting,
                AsrPhase = ClassScribe.Core.AsrPhase.Idle,
                AttemptID = attempt,
                FolderPath = currentFolder,
            };
            NotifyCurrentSessionChanged();
            await sessionStore.SaveMetadataAsync(currentMetadata, currentFolder, cancellationToken)
                .ConfigureAwait(true);
            if (!IsCurrent(attempt))
            {
                return;
            }

            SetStatus("StatusWaitingAudio");
            captureStartInvoked = true;
            await audioCapture.StartAsync(
                    source,
                    currentFolder,
                    attempt,
                    cancellationToken,
                    systemOutputAuthorization)
                .ConfigureAwait(true);
            captureStarted = true;
            if (!IsCurrent(attempt))
            {
                return;
            }

            IsRecording = true;
            currentMetadata = currentMetadata with
            {
                AudioManifestReference = captureScope == CaptureScope.Microphone
                    ? null
                    : File.Exists(Path.Combine(currentFolder, "audio-manifest.json"))
                        ? new AudioManifestReference()
                        : null,
                State = ProcessingState.Recording,
                SessionPhase = ClassScribe.Core.SessionPhase.Recording,
                CapturePhase = ClassScribe.Core.CapturePhase.Recording,
                AsrPhase = ClassScribe.Core.AsrPhase.WaitingForSpeech,
            };
            await sessionStore.SaveMetadataAsync(currentMetadata, currentFolder, cancellationToken)
                .ConfigureAwait(true);
            if (!IsCurrent(attempt))
            {
                return;
            }

            if (audioCapture.SignalHealth is { } signalHealth)
            {
                ApplyCaptureSignal(signalHealth, attempt);
            }
            else
            {
                SetStatus("StatusRecordingSaved");
            }
            StartBackgroundLoops();
        }
        catch (OperationCanceledException)
        {
            if (!IsCurrent(attempt))
            {
                return;
            }

            SetStatus("StatusStartCancelled");
            await MarkCurrentStateAsync(ProcessingState.Cancelled, attempt).ConfigureAwait(true);
        }
        catch (Exception error)
        {
            if (!IsCurrent(attempt))
            {
                return;
            }

            if (captureStartInvoked
                && CaptureRecoveryPolicy.CanSuggestSystemOutput(
                    audioCapture.LastStartFailureCategory ?? CaptureFailureCategory.Other,
                    captureScope))
            {
                captureRecoverySuggestion = CaptureRecoverySuggestion.SystemOutput;
                OnPropertyChanged(nameof(ShowSystemOutputRecovery));
            }
            SetWarningRaw(error.Message);
            SetStatus("StatusStartFailed");
            await MarkCurrentStateAsync(ProcessingState.Failed, attempt).ConfigureAwait(true);
        }
        finally
        {
            try
            {
                processingCancellation?.Dispose();
                processingCancellation = null;
                IsBusy = false;
                NotifyAvailability();
                await RefreshHistoryAsync(attempt).ConfigureAwait(true);
            }
            finally
            {
                if (!captureStarted && systemOutputAuthorization is not null)
                {
                    audioCapture.InvalidateSystemOutputAuthorization(attempt);
                }
                if (!captureStarted)
                {
                    UnregisterCaptureCallbacks(attempt);
                }
                CompleteOperation(operation);
            }
        }
    }

    public void TogglePause()
    {
        if (!CanPause)
        {
            return;
        }

        IsPaused = !IsPaused;
        SetStatus(IsPaused ? "StatusRecordingPaused" : "StatusRecording");
    }

    public Task StopAsync() => StopAsync(processAfterStop: true);

    public Task StopForExitAsync() => StopAsync(processAfterStop: false);

    internal int FinalProcessingInvocationCountForTest =>
        Volatile.Read(ref finalProcessingInvocationCountForTest);

    internal void RecordCaptureFailureForTest(
        Exception error,
        CaptureFailureCategory category) =>
        audioCapture.RecordFailureForTest(error, category);

    internal void ApplyCaptureFaultForTest(CaptureFault fault)
    {
        if (activeAttempt is null)
        {
            throw new InvalidOperationException("No hay un intento de captura activo.");
        }

        ApplyCaptureFault(fault);
    }

    internal void PublishLiveTextForTest(string incoming) => PublishLiveText(incoming);

    internal void UpdateModelProgressForTest(ModelDownloadProgress progress) =>
        UpdateModelProgress(progress, activeAttempt);

    private async Task StopAsync(bool processAfterStop)
    {
        if (!CanStop)
        {
            return;
        }

        var attempt = activeAttempt;
        if (attempt is null)
        {
            return;
        }

        var operation = BeginOperation();
        IsBusy = true;
        IsPaused = false;
        WarningText = string.Empty;
        isStopping = true;
        SetStatus("StatusClosingAudio");
        processingCancellation = new CancellationTokenSource();
        NotifyAvailability();

        try
        {
            await StopBackgroundLoopsAsync().ConfigureAwait(true);
            if (!IsCurrent(attempt))
            {
                return;
            }

            var wavePath = await audioCapture.StopAsync(CancellationToken.None).ConfigureAwait(true);
            UnregisterCaptureCallbacks(attempt);
            if (!IsCurrent(attempt))
            {
                return;
            }

            IsRecording = false;
            if (audioCapture.LastWarning is { } captureWarning)
            {
                WarningText = captureWarning;
            }
            var duration = PcmWaveFile.Validate(wavePath);
            if (currentMetadata is null || currentFolder is null)
            {
                throw new InvalidOperationException("La sesión activa perdió sus metadatos.");
            }

            currentMetadata = currentMetadata with
            {
                Duration = duration,
                State = ProcessingState.FinalizingAudio,
                SessionPhase = ClassScribe.Core.SessionPhase.Stopping,
                CapturePhase = ClassScribe.Core.CapturePhase.Stopping,
                AsrPhase = ClassScribe.Core.AsrPhase.Idle,
            };
            await sessionStore.SaveLiveAsync(
                    LiveText,
                    currentMetadata,
                    currentFolder,
                    "audio-finalized",
                    CancellationToken.None)
                .ConfigureAwait(true);
            if (!IsCurrent(attempt))
            {
                return;
            }

            await sessionStore.SaveMetadataAsync(currentMetadata, currentFolder, CancellationToken.None)
                .ConfigureAwait(true);
            if (!IsCurrent(attempt))
            {
                return;
            }

            if (processAfterStop)
            {
                await ProcessWaveAsync(
                        wavePath,
                        qualitySegments.ToArray(),
                        qualityTranscribedThroughSeconds,
                        qualityCoverageHasGap,
                        processingCancellation.Token)
                    .ConfigureAwait(true);
                if (!IsCurrent(attempt))
                {
                    return;
                }
            }
            else
            {
                currentMetadata = currentMetadata with
                {
                    State = ProcessingState.Recoverable,
                    SessionPhase = ClassScribe.Core.SessionPhase.Recoverable,
                    CapturePhase = ClassScribe.Core.CapturePhase.FailedRecoverable,
                    AsrPhase = ClassScribe.Core.AsrPhase.FailedRecoverable,
                };
                await sessionStore.SaveMetadataAsync(currentMetadata, currentFolder, CancellationToken.None)
                    .ConfigureAwait(true);
                if (!IsCurrent(attempt))
                {
                    return;
                }

                SetStatus("StatusSessionSavedRetry");
            }
        }
        catch (OperationCanceledException)
        {
            if (!IsCurrent(attempt))
            {
                return;
            }

            IsRecording = false;
            SetStatus("StatusProcessCancelled");
            await MarkCurrentStateAsync(ProcessingState.Cancelled, attempt).ConfigureAwait(true);
        }
        catch (Exception error)
        {
            if (!IsCurrent(attempt))
            {
                return;
            }

            IsRecording = false;
            if (error is CaptureTerminalException terminal
                && (terminal.Category is CaptureFailureCategory.DurableMaster
                    or CaptureFailureCategory.Storage))
            {
                captureRecoverySuggestion = null;
                OnPropertyChanged(nameof(ShowSystemOutputRecovery));
                SetWarning("WarningCapture", terminal.Message);
                SetStatus(terminal.PreservedWavePath is not null
                    ? "StatusPartialSaved"
                    : "StatusSessionSavedRetry");
                await PersistRecoverableLiveTextAsync(attempt).ConfigureAwait(true);
                await MarkCurrentStateAsync(ProcessingState.Recoverable, attempt).ConfigureAwait(true);
                return;
            }

            SetWarningRaw(error.Message);
            SetStatus("StatusSessionSavedRetry");
            await MarkCurrentStateAsync(ProcessingState.Failed, attempt).ConfigureAwait(true);
        }
        finally
        {
            try
            {
                await StopBackgroundLoopsAsync().ConfigureAwait(true);
                processingCancellation?.Dispose();
                processingCancellation = null;
                IsBusy = false;
                isStopping = false;
                ModelProgress = 0;
                NotifyAvailability();
                await RefreshHistoryAsync(attempt).ConfigureAwait(true);
            }
            finally
            {
                UnregisterCaptureCallbacks(attempt);
                CompleteOperation(operation);
            }
        }
    }

    public void CancelCurrentOperation()
    {
        if (pendingSystemOutputConsent is not null)
        {
            InvalidatePendingSystemOutputConsent();
            SetStatus("StatusComputerAudioCancelled");
            return;
        }

        processingCancellation?.Cancel();
        SetStatus("StatusSafeCancel");
    }

    public async Task LoadSelectedHistoryAsync()
    {
        if (pendingSystemOutputConsent is not null)
        {
            InvalidatePendingSystemOutputConsent();
            return;
        }

        if (SelectedHistory is null || IsRecording || IsBusy)
        {
            return;
        }

        await LoadSessionAsync(SelectedHistory.Session).ConfigureAwait(true);
    }

    public async Task ReprocessCurrentAsync()
    {
        if (pendingSystemOutputConsent is not null)
        {
            InvalidatePendingSystemOutputConsent();
            return;
        }

        if (!CanReprocess || currentFolder is null || currentMetadata is null)
        {
            SetWarning("StatusReprocessUnavailable");
            return;
        }

        var operation = BeginOperation();
        var attempt = BeginAttempt(currentMetadata.Id);
        currentMetadata = currentMetadata with { AttemptID = attempt };
        asrOriginalReference = null;
        activeDiarizationProposal = null;
        IsBusy = true;
        WarningText = string.Empty;
        processingCancellation = new CancellationTokenSource();
        NotifyAvailability();
        try
        {
            var wavePath = await sessionStore.RecoverRawAudioAsync(
                    currentFolder,
                    processingCancellation.Token)
                .ConfigureAwait(true);
            if (!IsCurrent(attempt))
            {
                return;
            }

            currentMetadata = currentMetadata with
            {
                Duration = PcmWaveFile.Validate(wavePath),
                State = ProcessingState.FinalTranscription,
                SessionPhase = ClassScribe.Core.SessionPhase.Processing,
                CapturePhase = ClassScribe.Core.CapturePhase.Idle,
                AsrPhase = ClassScribe.Core.AsrPhase.PreparingLoad,
            };
            await ProcessWaveAsync(wavePath, processingCancellation.Token).ConfigureAwait(true);
        }
        catch (OperationCanceledException)
        {
            if (!IsCurrent(attempt))
            {
                return;
            }

            SetStatus("StatusReprocessCancelled");
            await MarkCurrentStateAsync(ProcessingState.Cancelled, attempt).ConfigureAwait(true);
        }
        catch (Exception error)
        {
            if (!IsCurrent(attempt))
            {
                return;
            }

            SetWarningRaw(error.Message);
            SetStatus("StatusReprocessFailed");
            await MarkCurrentStateAsync(ProcessingState.Failed, attempt).ConfigureAwait(true);
        }
        finally
        {
            try
            {
                processingCancellation?.Dispose();
                processingCancellation = null;
                IsBusy = false;
                ModelProgress = 0;
                NotifyAvailability();
                await RefreshHistoryAsync(attempt).ConfigureAwait(true);
            }
            finally
            {
                CompleteOperation(operation);
            }
        }
    }

    public async Task ApplyProfessorSelectionAsync()
    {
        if (currentMetadata is null || currentFolder is null || segments.Count == 0)
        {
            return;
        }

        var attempt = activeAttempt;
        if (!IsCurrent(attempt))
        {
            return;
        }

        var metadata = currentMetadata;
        var folder = currentFolder;
        var allSegments = segments.ToArray();
        var review = ReviewRows.Select(static row => row.ToModel()).ToArray();
        var selectedProfessorID = SelectedProfessor?.Id;
        var professor = SpeakerAssignment.ProfessorSegments(
            allSegments,
            selectedProfessorID,
            review);
        ProfessorText = TranscriptExporter.PlainText(professor, Speakers.Select(static speaker => speaker.Model).ToArray());
        metadata = metadata with
        {
            ProfessorSpeakerID = selectedProfessorID,
            ProfessorSelectionIsAutomatic = false,
            State = ProcessingState.Complete,
            SessionPhase = ClassScribe.Core.SessionPhase.Complete,
            CapturePhase = ClassScribe.Core.CapturePhase.Idle,
            AsrPhase = ClassScribe.Core.AsrPhase.Idle,
        };
        var professorOperation = new SpeakerCorrectionOperation
        {
            Id = Guid.NewGuid(),
            Kind = SpeakerCorrectionKind.ProfessorConfirmation,
            SpeakerID = selectedProfessorID,
            SegmentIDs = [],
            CreatedAt = DateTimeOffset.UtcNow,
        };
        var humanCorrection = new HumanCorrectionUpdate
        {
            Operations = new[] { professorOperation }
                .Concat(CreateReviewCorrectionOperations())
                .ToArray(),
            ClearProfessorText = true,
        };
        var speakers = Speakers.Select(static speaker => speaker.Model).ToArray();
        var diarizationProposal = activeDiarizationProposal;
        await sessionStore.SaveFinalAsync(
                metadata,
                allSegments,
                professor,
                review,
                speakers,
                folder,
                humanCorrection: humanCorrection,
                diarizationProposal: diarizationProposal)
            .ConfigureAwait(true);
        if (!IsCurrent(attempt))
        {
            return;
        }

        currentMetadata = metadata;
        RememberHumanCorrection(humanCorrection);
        ApplyActiveHumanCorrectionText();

        SetStatus("StatusProfessorSaved");
    }

    public async Task RenameSelectedSpeakerAsync()
    {
        if (SelectedSpeaker is null
            || string.IsNullOrWhiteSpace(SpeakerNameDraft)
            || !CanEditSpeakers)
        {
            return;
        }

        await ApplySpeakerCorrectionAsync(new SpeakerCorrectionOperation
        {
            Id = Guid.NewGuid(),
            Kind = SpeakerCorrectionKind.Rename,
            SpeakerID = SelectedSpeaker.Id,
            DisplayName = SpeakerNameDraft.Trim(),
            CreatedAt = DateTimeOffset.UtcNow,
        }).ConfigureAwait(true);
    }

    public async Task MergeSelectedSpeakersAsync()
    {
        if (SelectedSpeaker is null
            || SelectedMergeTarget is null
            || !SpeakerCorrectionProjection.CanMerge(
                SelectedMergeTarget.Id,
                SelectedSpeaker.Id,
                activeHumanCorrectionOverlay?.Operations ?? [],
                Speakers.Select(static speaker => speaker.Id).ToHashSet(StringComparer.Ordinal))
            || !CanEditSpeakers)
        {
            return;
        }

        // Keep the selected speaker as the canonical identity and fold the
        // merge target into it. This makes the operation deterministic.
        await ApplySpeakerCorrectionAsync(new SpeakerCorrectionOperation
        {
            Id = Guid.NewGuid(),
            Kind = SpeakerCorrectionKind.Merge,
            SpeakerID = SelectedMergeTarget.Id,
            TargetSpeakerID = SelectedSpeaker.Id,
            CreatedAt = DateTimeOffset.UtcNow,
        }).ConfigureAwait(true);
    }

    public async Task ReassignSelectedSegmentAsync()
    {
        if (SelectedReviewRow is null
            || SelectedCorrectionSpeaker is null
            || !CanEditSpeakers
            || SelectedCorrectionSpeaker.Id == SelectedReviewRow.Item.Segment.SpeakerID)
        {
            return;
        }

        var segment = SelectedReviewRow.Item.Segment;
        await ApplySpeakerCorrectionAsync(new SpeakerCorrectionOperation
        {
            Id = Guid.NewGuid(),
            Kind = SpeakerCorrectionKind.Reassign,
            SpeakerID = segment.SpeakerID,
            TargetSpeakerID = SelectedCorrectionSpeaker.Id,
            SegmentIDs = [segment.Id],
            AnchorStart = segment.Start,
            AnchorEnd = segment.End,
            AnchorText = segment.Text,
            CreatedAt = DateTimeOffset.UtcNow,
        }).ConfigureAwait(true);
    }

    public async Task SplitSelectedSegmentAsync()
    {
        if (SelectedReviewRow is null
            || SelectedSplitBoundary is null
            || !CanSplitSelectedReview)
        {
            return;
        }

        var segment = SelectedReviewRow.Item.Segment;
        await ApplySpeakerCorrectionAsync(new SpeakerCorrectionOperation
        {
            Id = Guid.NewGuid(),
            Kind = SpeakerCorrectionKind.Split,
            SpeakerID = segment.SpeakerID,
            SegmentIDs = [segment.Id],
            AnchorStart = segment.Start,
            AnchorEnd = segment.End,
            AnchorText = segment.Text,
            SplitAfterWordIndex = SelectedSplitBoundary.AfterWordIndex,
            CreatedAt = DateTimeOffset.UtcNow,
        }).ConfigureAwait(true);
    }

    private async Task ApplySpeakerCorrectionAsync(SpeakerCorrectionOperation operation)
    {
        if (currentMetadata is null || currentFolder is null || segments.Count == 0)
        {
            return;
        }

        var existingOverlay = activeHumanCorrectionOverlay ?? new HumanCorrectionOverlay();
        var overlay = existingOverlay with
        {
            Operations = existingOverlay.Operations
                .Concat([operation])
                .ToArray(),
        };
        var result = SpeakerCorrectionProjection.Apply(
            segments,
            Speakers.Select(static speaker => speaker.Model).ToArray(),
            ReviewRows.Select(static row => row.ToModel()).ToArray(),
            SelectedProfessor?.Id ?? currentMetadata.ProfessorSpeakerID,
            currentMetadata.ProfessorSelectionIsAutomatic,
            overlay);
        if (result.UnresolvedOperationIDs.Contains(operation.Id))
        {
            SetWarning("WarningSpeakerCorrectionUnresolved");
            return;
        }

        var professor = SpeakerAssignment.ProfessorSegments(
            result.Segments,
            result.ProfessorSpeakerID,
            result.Review);
        var metadata = currentMetadata with
        {
            SpeakerCount = result.Speakers.Count,
            ProfessorSpeakerID = result.ProfessorSpeakerID,
            ProfessorSelectionIsAutomatic = result.ProfessorSelectionIsAutomatic,
            HumanCorrectionOverlayReference = currentMetadata.HumanCorrectionOverlayReference
                ?? new HumanCorrectionOverlayReference { RelativePath = "human-correction-overlay.json" },
        };
        var update = new HumanCorrectionUpdate
        {
            Operations = new[] { operation }
                .Concat(CreateReviewCorrectionOperations())
                .ToArray(),
            ClearAllText = true,
            ClearProfessorText = true,
        };
        await sessionStore.SaveFinalAsync(
                metadata,
                result.Segments,
                professor,
                result.Review,
                result.Speakers,
                currentFolder,
                humanCorrection: update,
                diarizationProposal: activeDiarizationProposal)
            .ConfigureAwait(true);
        if (!IsCurrent(activeAttempt))
        {
            return;
        }

        currentMetadata = metadata;
        activeHumanCorrectionOverlay = overlay;
        segments.Clear();
        segments.AddRange(result.Segments);
        Speakers.Clear();
        foreach (var speaker in result.Speakers)
        {
            Speakers.Add(new SpeakerChoice(speaker, localization));
        }

        ReviewRows.Clear();
        foreach (var item in result.Review)
        {
            ReviewRows.Add(CreateReviewRow(item));
        }

        SelectedProfessor = Speakers.FirstOrDefault(speaker =>
            speaker.Id == result.ProfessorSpeakerID);
        SelectedSpeaker = SelectedProfessor ?? Speakers.FirstOrDefault();
        SelectedMergeTarget = MergeTargets.FirstOrDefault();
        AllText = TranscriptExporter.PlainText(result.Segments, result.Speakers);
        ProfessorText = TranscriptExporter.PlainText(professor, result.Speakers);
        RefreshSplitBoundaries();
        SetStatus("StatusSpeakerCorrectionsSaved");
        await RefreshHistoryAsync(activeAttempt).ConfigureAwait(true);
        NotifyCorrectionAvailability();
    }

    private void RefreshSplitBoundaries()
    {
        SplitBoundaries.Clear();
        SelectedSplitBoundary = null;
        if (SelectedReviewRow?.Item.Segment.WordTimings is not { Count: > 1 } timings
            || !SpeakerCorrectionProjection.CanSplit(SelectedReviewRow.Item.Segment))
        {
            return;
        }

        for (var index = 0; index < timings.Count - 1; index++)
        {
            SplitBoundaries.Add(new SplitBoundaryChoice(
                index + 1,
                localization.Get("SplitAfterWord", timings[index].Text)));
        }

        SelectedSplitBoundary = SplitBoundaries.FirstOrDefault();
    }

    private void NotifyCorrectionAvailability()
    {
        OnPropertyChanged(nameof(CanEditSpeakers));
        OnPropertyChanged(nameof(CanSplitSelectedReview));
        OnPropertyChanged(nameof(HasSpeakerCorrections));
        OnPropertyChanged(nameof(MergeTargets));
    }

    private ReviewRow CreateReviewRow(ReviewItem item) =>
        new(
            item,
            localization,
            Speakers.FirstOrDefault(speaker => speaker.Id == item.Segment.SpeakerID)?.Model.DisplayName);

    private IReadOnlyList<SpeakerCorrectionOperation> CreateReviewCorrectionOperations() =>
        ReviewRows.Select(row =>
        {
            var segment = row.Item.Segment;
            return new SpeakerCorrectionOperation
            {
                Id = Guid.NewGuid(),
                Kind = SpeakerCorrectionKind.Review,
                SpeakerID = segment.SpeakerID,
                SegmentIDs = [segment.Id],
                AnchorStart = segment.Start,
                AnchorEnd = segment.End,
                AnchorText = segment.Text,
                IsActive = row.IncludeForProfessor,
                CreatedAt = DateTimeOffset.UtcNow,
            };
        }).ToArray();

    public async Task SaveEditsAsync()
    {
        if (currentMetadata is null || currentFolder is null)
        {
            return;
        }

        var attempt = activeAttempt;
        if (!IsCurrent(attempt))
        {
            return;
        }

        var metadata = currentMetadata;
        var folder = currentFolder;
        var humanCorrection = new HumanCorrectionUpdate
        {
            AllText = AllText,
            ProfessorText = ProfessorText,
            Operations = CreateReviewCorrectionOperations(),
        };

        if (segments.Count == 0)
        {
            await sessionStore.SaveEditedDocumentsAsync(
                    metadata,
                    folder,
                    humanCorrection.AllText!,
                    humanCorrection.ProfessorText!)
                .ConfigureAwait(true);
            if (!IsCurrent(attempt))
            {
                return;
            }
        }
        else
        {
            var allSegments = segments.ToArray();
            var review = ReviewRows.Select(static row => row.ToModel()).ToArray();
            var selectedProfessorID = SelectedProfessor?.Id ?? metadata.ProfessorSpeakerID;
            var professor = SpeakerAssignment.ProfessorSegments(
                allSegments,
                selectedProfessorID,
                review);
            var speakers = Speakers.Select(static speaker => speaker.Model).ToArray();
            var diarizationProposal = activeDiarizationProposal;
            await sessionStore.SaveFinalAsync(
                    metadata,
                    allSegments,
                    professor,
                    review,
                    speakers,
                    folder,
                    humanCorrection: humanCorrection,
                    diarizationProposal: diarizationProposal)
                .ConfigureAwait(true);
            if (!IsCurrent(attempt))
            {
                return;
            }
        }

        RememberHumanCorrection(humanCorrection);
        SetStatus("StatusEditsSaved");
        await RefreshHistoryAsync(attempt).ConfigureAwait(true);
    }

    public string ChatEnvelope() => currentMetadata is null
        ? TranscriptActions.FullTranscript(AllText, LiveText)
        : TranscriptActions.ChatEnvelope(
            currentMetadata.Subject,
            currentMetadata.StartedAt,
            currentMetadata.Duration,
            currentMetadata.Mode,
            currentMetadata.Source,
            TranscriptActions.FullTranscript(AllText, LiveText),
            localization.MetadataLabels,
            localization.Culture);

    public string? CurrentFolder => currentFolder;

    public DateTimeOffset CurrentStartedAt => currentMetadata?.StartedAt ?? DateTimeOffset.Now;

    public async ValueTask DisposeAsync()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        localization.PropertyChanged -= Localization_PropertyChanged;
        InvalidatePendingSystemOutputConsent();
        liveCancellation?.Cancel();
        timerCancellation?.Cancel();
        processingCancellation?.Cancel();
        if (activeOperation?.Task is { } operation)
        {
            await operation.ConfigureAwait(false);
        }
        await StopBackgroundLoopsAsync().ConfigureAwait(false);
        UnregisterCaptureCallbacks();
        activeAttempt = null;
        await audioCapture.DisposeAsync().ConfigureAwait(false);
        await transcriber.DisposeAsync().ConfigureAwait(false);
        modelProvisioner.Dispose();
        liveCancellation?.Dispose();
        timerCancellation?.Dispose();
        processingCancellation?.Dispose();
    }

    public void ReportUiError(Exception error)
    {
        CrashLog.Write(error);
        SetWarningRaw(error.Message);
        SetStatus("StatusOperationFailed");
    }

    private void SetStatus(string key, params object?[] arguments)
    {
        statusMessage = LocalizedMessage.Keyed(key, arguments);
        OnPropertyChanged(nameof(StatusText));
    }

    private void SetWarning(string key, params object?[] arguments)
    {
        warningMessage = LocalizedMessage.Keyed(key, arguments);
        OnPropertyChanged(nameof(WarningText));
        OnPropertyChanged(nameof(HasWarning));
    }

    private void SetWarningRaw(string value)
    {
        warningMessage = string.IsNullOrEmpty(value) ? null : LocalizedMessage.Raw(value);
        OnPropertyChanged(nameof(WarningText));
        OnPropertyChanged(nameof(HasWarning));
    }

    private void Localization_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        foreach (var choice in CaptureModes)
        {
            choice.Refresh(localization);
        }

        foreach (var choice in OnlineSourceChoices)
        {
            choice.Refresh(localization);
        }

        foreach (var choice in Languages)
        {
            choice.Refresh(localization);
        }

        foreach (var speaker in Speakers)
        {
            speaker.RefreshLocalization();
        }

        foreach (var row in ReviewRows)
        {
            row.RefreshLocalization();
        }

        foreach (var row in History)
        {
            row.RefreshLocalization();
        }

        OnPropertyChanged(nameof(InterfaceLanguageCode));
        OnPropertyChanged(nameof(StatusText));
        OnPropertyChanged(nameof(WarningText));
        OnPropertyChanged(nameof(PauseButtonText));
        OnPropertyChanged(nameof(CurrentFolderLabel));
    }

    private void StartBackgroundLoops()
    {
        liveCancellation?.Dispose();
        timerCancellation?.Dispose();
        liveCancellation = new CancellationTokenSource();
        timerCancellation = new CancellationTokenSource();
        liveTask = RunLiveTranscriptionAsync(liveCancellation.Token);
        timerTask = RunElapsedTimerAsync(timerCancellation.Token);
    }

    private async Task StopBackgroundLoopsAsync()
    {
        liveCancellation?.Cancel();
        timerCancellation?.Cancel();
        await IgnoreCancellationAsync(liveTask).ConfigureAwait(true);
        await IgnoreCancellationAsync(timerTask).ConfigureAwait(true);
        liveTask = null;
        timerTask = null;
    }

    private async Task RunElapsedTimerAsync(CancellationToken cancellationToken)
    {
        var attempt = activeAttempt;
        if (attempt is null)
        {
            return;
        }

        using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(500));
        while (await timer.WaitForNextTickAsync(cancellationToken).ConfigureAwait(false))
        {
            if (!IsCurrent(attempt))
            {
                break;
            }

            var duration = audioCapture.DurationSeconds;
            _ = audioCapture.EvaluateSignalHealth(attempt);
            RunOnUi(() =>
            {
                if (IsCurrent(attempt))
                {
                    ElapsedText = Timecode.Display(duration);
                }
            });
        }
    }

    private async Task RunLiveTranscriptionAsync(CancellationToken cancellationToken)
    {
        var attempt = activeAttempt;
        await Task.Delay(TimeSpan.FromSeconds(4), cancellationToken).ConfigureAwait(false);
        if (!IsCurrent(attempt))
        {
            return;
        }

        while (!cancellationToken.IsCancellationRequested)
        {
            if (!IsCurrent(attempt))
            {
                break;
            }

            if (!IsPaused)
            {
                try
                {
                    var duration = audioCapture.DurationSeconds;
                    await RunQualityCheckpointAsync(duration, attempt, cancellationToken)
                        .ConfigureAwait(false);
                    if (!IsCurrent(attempt))
                    {
                        break;
                    }

                    duration = audioCapture.DurationSeconds;
                    var pendingDuration = Math.Max(0, duration - liveTranscribedThroughSeconds);
                    var pcm = audioCapture.Snapshot(TimeSpan.FromSeconds(pendingDuration));
                    if (pcm.Length >= PcmWaveFile.SampleRate * 2)
                    {
                        var pcmDuration = pcm.Length / 32_000d;
                        var missingDuration = Math.Max(0, pendingDuration - pcmDuration);
                        var offset = liveTranscribedThroughSeconds;
                        if (missingDuration > 1)
                        {
                            offset = Math.Max(0, duration - pcmDuration);
                        }

                        var sessionVocabulary = currentMetadata?.TechnicalVocabulary ?? string.Empty;
                        var sessionLanguage = NormalizeLanguage(currentMetadata?.Language);
                        var provisional = await transcriber.TranscribePcmAsync(
                                pcm,
                                sessionVocabulary,
                                sessionLanguage,
                                offset,
                                progress: null,
                            cancellationToken)
                            .ConfigureAwait(false);
                        if (!IsCurrent(attempt))
                        {
                            break;
                        }

                        liveTranscribedThroughSeconds = offset + pcmDuration;
                        var incoming = string.Join(' ', provisional.Select(static segment => segment.Text));
                        if (incoming.Length > 0)
                        {
                            var visibleText = string.Empty;
                            await RunOnUiAsync(() =>
                                {
                                    if (IsCurrent(attempt))
                                    {
                                        PublishLiveText(incoming);
                                        visibleText = LiveText;
                                    }
                                })
                                .ConfigureAwait(false);
                            if (!IsCurrent(attempt))
                            {
                                break;
                            }

                            var metadata = currentMetadata;
                            var folder = currentFolder;
                            if (metadata is not null && folder is not null)
                            {
                                metadata = metadata with
                                {
                                    Duration = duration,
                                    State = IsPaused
                                        ? ProcessingState.TranscriptionPaused
                                        : ProcessingState.Recording,
                                    SessionPhase = ClassScribe.Core.SessionPhase.Recording,
                                    CapturePhase = ClassScribe.Core.CapturePhase.Recording,
                                    AsrPhase = ClassScribe.Core.AsrPhase.Transcribing,
                                };
                                await sessionStore.SaveLiveAsync(
                                        visibleText,
                                        metadata,
                                        folder,
                                        $"live-{DateTimeOffset.UtcNow:yyyyMMddHHmmss}",
                                        cancellationToken)
                                    .ConfigureAwait(false);
                                if (!IsCurrent(attempt))
                                {
                                    break;
                                }
                            }
                        }
                    }
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    break;
                }
                catch (Exception error) when (error is not OutOfMemoryException)
                {
                    CrashLog.Write(error);
                    RunOnUi(() =>
                    {
                        if (IsCurrent(attempt)
                            && !IsTerminalCaptureFaultPresentationActive)
                        {
                            WarningText = $"El texto en vivo se reintentará: {error.Message}";
                            StatusText = "El audio sigue grabándose de forma segura";
                        }
                    });
                }
            }

            await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken).ConfigureAwait(false);
        }
    }

    private async Task RunQualityCheckpointAsync(
        double duration,
        SessionAttemptID? attempt,
        CancellationToken cancellationToken)
    {
        var pendingDuration = Math.Max(0, duration - qualityTranscribedThroughSeconds);
        if (qualityCoverageHasGap || pendingDuration < QualityCheckpointSeconds)
        {
            return;
        }

        var pcm = audioCapture.Snapshot(TimeSpan.FromSeconds(pendingDuration));
        var pcmDuration = pcm.Length / 32_000d;
        var missingDuration = Math.Max(0, pendingDuration - pcmDuration);
        if (pcm.Length < PcmWaveFile.SampleRate * 2 || missingDuration > 1)
        {
            qualityCoverageHasGap = true;
            return;
        }

        var offset = qualityTranscribedThroughSeconds;
        var checkpoint = await transcriber.TranscribePcmAsync(
                pcm,
                currentMetadata?.TechnicalVocabulary ?? string.Empty,
                NormalizeLanguage(currentMetadata?.Language),
                offset,
                progress: null,
                cancellationToken)
            .ConfigureAwait(false);
        if (!IsCurrent(attempt))
        {
            return;
        }

        qualitySegments.AddRange(checkpoint);
        qualityTranscribedThroughSeconds = offset + pcmDuration;
    }

    private Task ProcessWaveAsync(string wavePath, CancellationToken cancellationToken) =>
        ProcessWaveAsync(wavePath, [], 0, qualityCoverageHasGap: true, cancellationToken);

    private async Task ProcessWaveAsync(
        string wavePath,
        TranscriptSegment[] reusableQualitySegments,
        double transcribedThroughSeconds,
        bool qualityCoverageHasGap,
        CancellationToken cancellationToken)
    {
        Interlocked.Increment(ref finalProcessingInvocationCountForTest);
        if (currentMetadata is null || currentFolder is null)
        {
            throw new InvalidOperationException("No hay una sesión preparada para procesar.");
        }

        var attempt = activeAttempt;
        if (!IsCurrent(attempt))
        {
            return;
        }

        currentMetadata = currentMetadata with
        {
            State = ProcessingState.FinalTranscription,
            SessionPhase = ClassScribe.Core.SessionPhase.Processing,
            CapturePhase = ClassScribe.Core.CapturePhase.Idle,
            AsrPhase = ClassScribe.Core.AsrPhase.PreparingLoad,
        };
        await sessionStore.SaveMetadataAsync(currentMetadata, currentFolder, CancellationToken.None)
            .ConfigureAwait(true);
        if (!IsCurrent(attempt))
        {
            return;
        }

        SetStatus("StatusFinalPreparing");
        ModelProgress = 0;
        var progress = new Progress<ModelDownloadProgress>(
            value => UpdateModelProgress(value, attempt));
        using var diarizationCancellation = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken);
        var diarizationTask = PrepareDiarizationAsync(
            wavePath,
            progress,
            diarizationCancellation.Token);
        IReadOnlyList<TranscriptSegment> finalSegments;
        try
        {
            if (reusableQualitySegments.Length > 0 && !qualityCoverageHasGap)
            {
                const double tailOverlapSeconds = 1.5;
                var duration = PcmWaveFile.Validate(wavePath);
                var tailStart = Math.Max(
                    0,
                    Math.Min(duration, transcribedThroughSeconds) - tailOverlapSeconds);
                var tailPcm = await PcmWaveFile.ReadPcmTailAsync(
                        wavePath,
                        tailStart,
                        cancellationToken)
                    .ConfigureAwait(true);
                var tailSegments = tailPcm.Length == 0
                    ? []
                    : await transcriber.TranscribePcmAsync(
                            tailPcm,
                            currentMetadata.TechnicalVocabulary,
                            NormalizeLanguage(currentMetadata.Language),
                            tailStart,
                            progress,
                            cancellationToken)
                        .ConfigureAwait(true);
                finalSegments = reusableQualitySegments
                    .Where(segment => segment.End <= tailStart)
                    .Concat(tailSegments)
                    .OrderBy(static segment => segment.Start)
                    .Select(static segment => segment with { Provisional = false })
                    .ToArray();
            }
            else
            {
                finalSegments = await transcriber.TranscribeFileAsync(
                        wavePath,
                        currentMetadata.TechnicalVocabulary,
                        NormalizeLanguage(currentMetadata.Language),
                        progress,
                        cancellationToken)
                    .ConfigureAwait(true);
            }
        }
        catch
        {
            diarizationCancellation.Cancel();
            await ObserveFailureAsync(diarizationTask).ConfigureAwait(true);
            throw;
        }
        if (!IsCurrent(attempt))
        {
            return;
        }

        if (finalSegments.Count == 0)
        {
            throw new InvalidDataException("No se detectó voz suficiente en la grabación.");
        }

        segments.Clear();
        segments.AddRange(finalSegments);
        AllText = TranscriptExporter.PlainText(segments, Speakers.Select(static speaker => speaker.Model).ToArray());
        ProfessorText = string.Empty;
        var humanProfessorSelection = !currentMetadata.ProfessorSelectionIsAutomatic;
        var humanProfessorSpeakerID = humanProfessorSelection
            ? currentMetadata.ProfessorSpeakerID
            : null;
        currentMetadata = currentMetadata with
        {
            State = ProcessingState.Diarizing,
            SessionPhase = ClassScribe.Core.SessionPhase.Processing,
            CapturePhase = ClassScribe.Core.CapturePhase.Idle,
            AsrPhase = ClassScribe.Core.AsrPhase.Idle,
            SpeakerCount = 0,
            ProfessorSpeakerID = humanProfessorSpeakerID,
        };

        asrOriginalReference = await sessionStore.SaveAsrOriginalAsync(
                currentMetadata,
                segments,
                currentFolder,
                CancellationToken.None)
            .ConfigureAwait(true);
        if (!IsCurrent(attempt))
        {
            return;
        }

        currentMetadata = currentMetadata with { AsrOriginalReference = asrOriginalReference };

        // Commit the complete transcript before consuming the isolated diarization result.
        await sessionStore.SaveAutomaticProjectionAsync(
                currentMetadata,
                segments,
                [],
                [],
                [],
                currentFolder,
                automaticAllText: AllText,
                automaticProfessorText: string.Empty,
                cancellationToken: CancellationToken.None)
            .ConfigureAwait(true);
        if (!IsCurrent(attempt))
        {
            return;
        }

        ApplyActiveHumanCorrectionText();

        IReadOnlyList<TranscriptSegment> assigned = segments.ToArray();
        IReadOnlyList<ReviewItem> review = [];
        IReadOnlyList<SpeakerRecord> speakers = [];
        string? diarizationWarning = null;
        try
        {
            SetStatus("StatusFinalizingSpeakers");
            var spans = await diarizationTask.ConfigureAwait(true);
            if (!IsCurrent(attempt))
            {
                return;
            }

            (assigned, review) = SpeakerAssignment.Assign(segments, spans);
            speakers = SpeakerAssignment.BuildSpeakers(assigned);
            activeDiarizationProposal = new DiarizationProposal
            {
                ProposalID = Guid.NewGuid(),
                CreatedAt = DateTimeOffset.UtcNow,
                EngineVersion = "windows-current",
                AsrRunID = asrOriginalReference?.RunID,
                Spans = spans,
            };
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            if (!IsCurrent(attempt))
            {
                return;
            }

            diarizationWarning = error.Message;
            (assigned, review) = SpeakerAssignment.Assign(segments, []);
        }

        if (!IsCurrent(attempt))
        {
            return;
        }

        segments.Clear();
        segments.AddRange(assigned);
        var automaticProfessorID = humanProfessorSelection
            ? humanProfessorSpeakerID
            : SpeakerAssignment.ProvisionalProfessor(speakers);
        var correctionProjection = SpeakerCorrectionProjection.Apply(
            assigned,
            speakers,
            review,
            automaticProfessorID,
            professorSelectionIsAutomatic: !humanProfessorSelection,
            activeHumanCorrectionOverlay ?? new HumanCorrectionOverlay());
        assigned = correctionProjection.Segments;
        review = correctionProjection.Review;
        speakers = correctionProjection.Speakers;
        var professorId = correctionProjection.ProfessorSpeakerID;
        var professor = SpeakerAssignment.ProfessorSegments(assigned, professorId, review);
        segments.Clear();
        segments.AddRange(assigned);
        AllText = TranscriptExporter.PlainText(assigned, speakers);
        ProfessorText = TranscriptExporter.PlainText(professor, speakers);
        Speakers.Clear();
        foreach (var speaker in speakers)
        {
            Speakers.Add(new SpeakerChoice(speaker, localization));
        }

        ReviewRows.Clear();
        foreach (var item in review)
        {
            ReviewRows.Add(CreateReviewRow(item));
        }

        SelectedProfessor = Speakers.FirstOrDefault(speaker => speaker.Id == professorId);
        SelectedSpeaker = Speakers.FirstOrDefault();
        SelectedMergeTarget = MergeTargets.FirstOrDefault();
        SelectedReviewRow = ReviewRows.FirstOrDefault();
        currentMetadata = currentMetadata with
        {
            State = ProcessingState.Complete,
            SessionPhase = ClassScribe.Core.SessionPhase.Complete,
            CapturePhase = ClassScribe.Core.CapturePhase.Idle,
            AsrPhase = ClassScribe.Core.AsrPhase.Idle,
            SpeakerCount = Speakers.Count,
            ProfessorSpeakerID = professorId,
            ProfessorSelectionIsAutomatic = correctionProjection.ProfessorSelectionIsAutomatic,
        };
        await sessionStore.SaveAutomaticProjectionAsync(
                currentMetadata,
                segments,
                professor,
                review,
                speakers,
                currentFolder,
                automaticAllText: AllText,
                automaticProfessorText: ProfessorText,
                cancellationToken: CancellationToken.None,
                diarizationProposal: activeDiarizationProposal)
            .ConfigureAwait(true);
        if (!IsCurrent(attempt))
        {
            return;
        }

        ApplyActiveHumanCorrectionText();

        ModelProgress = 1;
        if (diarizationWarning is null)
        {
            if (correctionProjection.UnresolvedOperationIDs.Count > 0)
            {
                SetWarning("WarningSpeakerCorrectionUnresolved");
            }
            else
            {
                WarningText = string.Empty;
            }
            SetStatus("StatusFinalReady");
        }
        else
        {
            SetWarning("WarningDiarization", diarizationWarning);
            SetStatus("StatusFinalReady");
        }

        NotifyCurrentSessionChanged();
        await RefreshHistoryAsync(attempt).ConfigureAwait(true);
    }

    private async Task LoadSessionAsync(SessionSummary summary)
    {
        IsBusy = true;
        NotifyAvailability();
        try
        {
            currentFolder = summary.Folder;
            currentMetadata = summary.Metadata;
            var attempt = BeginAttempt(summary.Metadata.Id);
            currentMetadata = currentMetadata with { AttemptID = attempt };
            if (summary.IsRecoverable)
            {
                currentMetadata = currentMetadata with
                {
                    State = ProcessingState.Recoverable,
                    SessionPhase = ClassScribe.Core.SessionPhase.Recoverable,
                    CapturePhase = ClassScribe.Core.CapturePhase.FailedRecoverable,
                    AsrPhase = ClassScribe.Core.AsrPhase.FailedRecoverable,
                };
            }
            asrOriginalReference = summary.Metadata.AsrOriginalReference;
            activeDiarizationProposal = null;
            Subject = summary.Metadata.Subject;
            Vocabulary = summary.Metadata.TechnicalVocabulary;
            SelectedLanguage = Languages.FirstOrDefault(language =>
                    language.Code == NormalizeLanguage(summary.Metadata.Language))
                ?? Languages[0];
            SelectedMode = CaptureModes.FirstOrDefault(mode => mode.Value == summary.Metadata.Mode)
                ?? CaptureModes[0];
            SelectedOnlineSource = OnlineSourceChoices.FirstOrDefault(source =>
                    source.Value == (summary.Metadata.CaptureScope == CaptureScope.SystemOutput
                        ? OnlineCaptureSource.SystemOutput
                        : OnlineCaptureSource.Application))
                ?? OnlineSourceChoices[0];

            var loadedSegments = await ReadJsonAsync<TranscriptSegment[]>(
                    Path.Combine(summary.Folder, "all-speakers.json"))
                .ConfigureAwait(true) ?? [];
            var loadedSpeakers = await ReadJsonAsync<SpeakerRecord[]>(
                    Path.Combine(summary.Folder, "speakers.json"))
                .ConfigureAwait(true) ?? [];
            var loadedReview = await ReadJsonAsync<ReviewItem[]>(Path.Combine(summary.Folder, "review.json"))
                .ConfigureAwait(true) ?? [];
            var loadedAll = await ReadTextAsync(Path.Combine(summary.Folder, "all-speakers.txt"))
                .ConfigureAwait(true);
            var loadedProfessor = await ReadTextAsync(Path.Combine(summary.Folder, "professor.txt"))
                .ConfigureAwait(true);
            var loadedOverlay = await ReadJsonAsync<HumanCorrectionOverlay>(
                    Path.Combine(summary.Folder, "human-correction-overlay.json"))
                .ConfigureAwait(true);
            var loadedLive = await ReadLiveTextAsync(summary.Folder).ConfigureAwait(true);
            if (!IsCurrent(attempt))
            {
                return;
            }

            activeHumanCorrectionOverlay = loadedOverlay;
            var restoredProjection = SpeakerCorrectionProjection.Apply(
                loadedSegments,
                loadedSpeakers,
                loadedReview,
                summary.Metadata.ProfessorSpeakerID,
                summary.Metadata.ProfessorSelectionIsAutomatic,
                loadedOverlay ?? new HumanCorrectionOverlay());
            segments.Clear();
            segments.AddRange(restoredProjection.Segments);
            AllText = loadedOverlay?.EditedAllText ?? TranscriptActions.BestAvailable(
                loadedAll,
                restoredProjection.Segments.Length > 0
                    ? TranscriptExporter.PlainText(restoredProjection.Segments, restoredProjection.Speakers)
                    : null,
                loadedLive);
            ProfessorText = loadedOverlay?.EditedProfessorText ?? loadedProfessor ?? string.Empty;
            SetLiveProgrammatically(loadedLive ?? string.Empty);
            Speakers.Clear();
            foreach (var speaker in restoredProjection.Speakers)
            {
                Speakers.Add(new SpeakerChoice(speaker, localization));
            }

            ReviewRows.Clear();
            foreach (var item in restoredProjection.Review)
            {
                ReviewRows.Add(CreateReviewRow(item));
            }

            SelectedProfessor = Speakers.FirstOrDefault(speaker =>
                speaker.Id == restoredProjection.ProfessorSpeakerID);
            SelectedSpeaker = Speakers.FirstOrDefault();
            SelectedMergeTarget = MergeTargets.FirstOrDefault();
            SelectedReviewRow = ReviewRows.FirstOrDefault();
            currentMetadata = currentMetadata with
            {
                SpeakerCount = restoredProjection.Speakers.Count,
                ProfessorSpeakerID = restoredProjection.ProfessorSpeakerID,
                ProfessorSelectionIsAutomatic = restoredProjection.ProfessorSelectionIsAutomatic,
            };
            captureRecoverySuggestion = null;
            OnPropertyChanged(nameof(ShowSystemOutputRecovery));
            if (!string.IsNullOrWhiteSpace(summary.RecoveryReason))
            {
                SetWarningRaw(summary.RecoveryReason);
            }
            else if (restoredProjection.UnresolvedOperationIDs.Count > 0)
            {
                SetWarning("WarningSpeakerCorrectionUnresolved");
            }
            else
            {
                SetWarningRaw(string.Empty);
            }
            SetStatus(summary.IsRecoverable ? "StatusRecoverableOpen" : "StatusSessionOpen");
            ElapsedText = Timecode.Display(summary.Metadata.Duration);
            NotifyCurrentSessionChanged();
        }
        finally
        {
            IsBusy = false;
            NotifyAvailability();
        }
    }

    private async Task RefreshHistoryAsync(SessionAttemptID? expectedAttempt = null)
    {
        if (expectedAttempt is not null && !IsCurrent(expectedAttempt))
        {
            return;
        }

        var selectedFolder = SelectedHistory?.Session.Folder;
        var sessions = await Task.Run(sessionStore.ScanSessions).ConfigureAwait(true);
        if (expectedAttempt is not null && !IsCurrent(expectedAttempt))
        {
            return;
        }

        History.Clear();
        foreach (var session in sessions)
        {
            History.Add(new HistoryRow(session, localization));
        }

        SelectedHistory = History.FirstOrDefault(row => row.Session.Folder == selectedFolder)
            ?? History.FirstOrDefault();
    }

    private async Task MarkCurrentStateAsync(ProcessingState state, SessionAttemptID? expectedAttempt = null)
    {
        if (expectedAttempt is not null && !IsCurrent(expectedAttempt))
        {
            return;
        }

        if (currentMetadata is null || currentFolder is null)
        {
            return;
        }

        currentMetadata = currentMetadata with
        {
            State = state,
            SessionPhase = state.ToSessionPhase(),
            CapturePhase = state.ToCapturePhase(),
            AsrPhase = state.ToAsrPhase(),
            AttemptID = activeAttempt ?? currentMetadata.AttemptID,
            Duration = Math.Max(currentMetadata.Duration, audioCapture.DurationSeconds),
        };
        try
        {
            await sessionStore.SaveMetadataAsync(currentMetadata, currentFolder, CancellationToken.None)
                .ConfigureAwait(true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            CrashLog.Write(error);
        }
    }

    private async Task PersistRecoverableLiveTextAsync(SessionAttemptID attempt)
    {
        if (!IsCurrent(attempt) || currentMetadata is null || currentFolder is null)
        {
            return;
        }

        try
        {
            await sessionStore.SaveLiveAsync(
                    LiveText,
                    currentMetadata,
                    currentFolder,
                    "capture-recoverable",
                    CancellationToken.None)
                .ConfigureAwait(true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            CrashLog.Write(error);
        }
    }

    private void PublishLiveText(string incoming)
    {
        var novel = OverlapDeduplicator.NovelText(automaticLiveText, incoming);
        automaticLiveText = OverlapDeduplicator.Merge(automaticLiveText, incoming);
        if (!liveWasEdited)
        {
            SetLiveProgrammatically(automaticLiveText);
        }
        else if (novel.Length > 0)
        {
            SetLiveProgrammatically(LiveText.Length == 0 ? novel : $"{LiveText.TrimEnd()} {novel}");
        }

        if (!IsTerminalCaptureFaultPresentationActive)
        {
            SetStatus(IsPaused ? "StatusRecordingPaused" : "StatusRecording");
            SetWarningRaw(string.Empty);
        }
    }

    private void ApplyCaptureSignal(CaptureSignalHealthSnapshot snapshot, SessionAttemptID attempt)
    {
        if (isStopping || !IsCurrent(attempt))
        {
            return;
        }

        SignalState = snapshot.State;
        if (IsTerminalCaptureFaultPresentationActive)
        {
            lastPresentedCaptureSignalState = snapshot.State;
            return;
        }

        if (!CaptureSignalPresentationPolicy.ShouldPresent(
                snapshot.State,
                lastPresentedCaptureSignalState,
                IsRecording))
        {
            return;
        }

        lastPresentedCaptureSignalState = snapshot.State;
        switch (snapshot.State)
        {
            case CaptureSignalState.AwaitingCallbacks:
                SetStatus("StatusCaptureAwaiting");
                break;
            case CaptureSignalState.NoCallbacks:
                SetStatus("StatusCaptureNoCallbacks");
                break;
            case CaptureSignalState.Silent:
                SetStatus("StatusCaptureSilent");
                break;
            case CaptureSignalState.Audible:
                SetStatus("StatusCaptureAudible");
                break;
        }
    }

    private void SetLiveProgrammatically(string value)
    {
        settingLiveProgrammatically = true;
        try
        {
            LiveText = value;
        }
        finally
        {
            settingLiveProgrammatically = false;
        }
    }

    private void UpdateModelProgress(ModelDownloadProgress progress, SessionAttemptID? expectedAttempt)
    {
        RunOnUi(() =>
        {
            if (!IsCurrent(expectedAttempt))
            {
                return;
            }

            ModelProgress = progress.Fraction;
            if (IsTerminalCaptureFaultPresentationActive)
            {
                return;
            }

            SetStatus(progress.ReceivedBytes < progress.TotalBytes
                ? "StatusDownloading"
                : "StatusModelDownloaded",
                progress.Name,
                progress.Fraction);
        });
    }

    private void ApplyActiveHumanCorrectionText()
    {
        if (activeHumanCorrectionOverlay?.EditedAllText is { } editedAllText)
        {
            AllText = editedAllText;
        }

        if (activeHumanCorrectionOverlay?.EditedProfessorText is { } editedProfessorText)
        {
            ProfessorText = editedProfessorText;
        }
    }

    private void RememberHumanCorrection(HumanCorrectionUpdate correction)
    {
        var existing = activeHumanCorrectionOverlay ?? new HumanCorrectionOverlay();
        activeHumanCorrectionOverlay = existing with
        {
            Operations = existing.Operations
                .Concat(correction.Operations.Where(operation =>
                    existing.Operations.All(previous => previous.Id != operation.Id)))
                .ToArray(),
            EditedAllText = correction.ClearAllText
                ? correction.AllText
                : correction.AllText ?? existing.EditedAllText,
            EditedProfessorText = correction.ClearProfessorText
                ? correction.ProfessorText
                : correction.ProfessorText ?? existing.EditedProfessorText,
        };
    }

    private void RegisterCaptureCallbacks(SessionAttemptID attempt)
    {
        UnregisterCaptureCallbacks();
        var lease = new SessionAttemptCallbackLease(attempt, candidate => IsCurrent(candidate));
        Action<SessionAttemptID, double> levelHandler = (eventAttempt, level) =>
        {
            if (eventAttempt != lease.Attempt)
            {
                return;
            }

            lease.TryAccept(() => RunOnUi(() => lease.TryAccept(() => AudioLevel = level)));
        };
        Action<SessionAttemptID, CaptureSignalHealthSnapshot> signalHealthHandler = (eventAttempt, snapshot) =>
        {
            if (eventAttempt != lease.Attempt)
            {
                return;
            }

            lease.TryAccept(() => RunOnUi(() => lease.TryAccept(() => ApplyCaptureSignal(snapshot, eventAttempt))));
        };
        Action<SessionAttemptID, CaptureFault> faultHandler = (eventAttempt, fault) =>
        {
            if (eventAttempt != lease.Attempt)
            {
                return;
            }

            lease.TryAccept(() => RunOnUi(() => lease.TryAccept(() => ApplyCaptureFault(fault))));
        };
        captureCallbackLease = lease;
        captureLevelHandler = levelHandler;
        captureSignalHealthHandler = signalHealthHandler;
        captureFaultHandler = faultHandler;
        audioCapture.LevelChanged += levelHandler;
        audioCapture.SignalHealthChanged += signalHealthHandler;
        audioCapture.CaptureFaulted += faultHandler;
    }

    private void UnregisterCaptureCallbacks(SessionAttemptID? expectedAttempt = null)
    {
        if (expectedAttempt is not null
            && !Equals(captureCallbackLease?.Attempt, expectedAttempt))
        {
            return;
        }

        captureCallbackLease?.Revoke();

        if (captureLevelHandler is not null)
        {
            audioCapture.LevelChanged -= captureLevelHandler;
        }

        if (captureSignalHealthHandler is not null)
        {
            audioCapture.SignalHealthChanged -= captureSignalHealthHandler;
        }

        if (captureFaultHandler is not null)
        {
            audioCapture.CaptureFaulted -= captureFaultHandler;
        }

        captureCallbackLease = null;
        captureLevelHandler = null;
        captureSignalHealthHandler = null;
        captureFaultHandler = null;
    }

    private void NotifyAvailability()
    {
        OnPropertyChanged(nameof(CanStart));
        OnPropertyChanged(nameof(CanStop));
        OnPropertyChanged(nameof(CanPause));
        OnPropertyChanged(nameof(CanCancel));
        OnPropertyChanged(nameof(CanReprocess));
        OnPropertyChanged(nameof(CanEditSpeakers));
        OnPropertyChanged(nameof(CanSplitSelectedReview));
        OnPropertyChanged(nameof(PendingSystemOutputConsent));
        OnPropertyChanged(nameof(ShowSystemOutputRecovery));
    }

    private TaskCompletionSource BeginOperation()
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (Interlocked.CompareExchange(ref activeOperation, completion, null) is not null)
        {
            throw new InvalidOperationException("Ya hay una operación principal en curso.");
        }

        return completion;
    }

    private void CompleteOperation(TaskCompletionSource completion)
    {
        completion.TrySetResult();
        _ = Interlocked.CompareExchange(ref activeOperation, null, completion);
    }

    private void NotifyCurrentSessionChanged()
    {
        OnPropertyChanged(nameof(HasCurrentSession));
        OnPropertyChanged(nameof(CurrentFolderLabel));
        OnPropertyChanged(nameof(CanReprocess));
        OnPropertyChanged(nameof(CurrentFolder));
        OnPropertyChanged(nameof(CurrentStartedAt));
    }

    private void NotifySourcePresentation()
    {
        OnPropertyChanged(nameof(IsOnline));
        OnPropertyChanged(nameof(IsInPerson));
        OnPropertyChanged(nameof(IsApplicationSource));
        OnPropertyChanged(nameof(IsSystemOutputSource));
    }

    private SessionAttemptID BeginAttempt(Guid sessionID)
    {
        if (activeAttempt is { } previousAttempt)
        {
            audioCapture.InvalidateSystemOutputAuthorization(previousAttempt);
        }

        var attempt = SessionAttemptID.Create(sessionID, ++attemptGeneration);
        activeAttempt = attempt;
        activeCaptureFault = null;
        return attempt;
    }

    private void InvalidateAttempt(SessionAttemptID attempt)
    {
        audioCapture.InvalidateSystemOutputAuthorization(attempt);
        if (activeAttempt == attempt)
        {
            activeAttempt = null;
            NotifyAvailability();
        }
    }

    private void InvalidatePendingSystemOutputConsent()
    {
        if (pendingSystemOutputConsent is not { } request)
        {
            return;
        }

        pendingSystemOutputConsent = null;
        OnPropertyChanged(nameof(PendingSystemOutputConsent));
        InvalidateAttempt(request.Attempt);
    }

    public void SelectSystemOutputAfterApplicationFailure()
    {
        if (!ShowSystemOutputRecovery)
        {
            return;
        }

        SelectedOnlineSource = OnlineSourceChoices.First(choice =>
            choice.Value == OnlineCaptureSource.SystemOutput);
        SetStatus("StatusSystemOutputSelected");
    }

    private bool IsCurrent(SessionAttemptID? attempt) =>
        attempt is not null && activeAttempt == attempt;

    private bool IsTerminalCaptureFaultPresentationActive =>
        IsRecording && activeCaptureFault is not null;

    private void ApplyCaptureFault(CaptureFault fault)
    {
        activeCaptureFault = fault;
        var canSuggestSystemOutput = CaptureRecoveryPolicy.CanSuggestSystemOutput(
            fault.Category,
            currentMetadata?.CaptureScope);
        captureRecoverySuggestion = canSuggestSystemOutput
            ? CaptureRecoverySuggestion.SystemOutput
            : null;
        OnPropertyChanged(nameof(ShowSystemOutputRecovery));
        SetWarning("WarningCapture", fault.Error.Message);
        SetStatus(fault.Category is CaptureFailureCategory.DurableMaster
            or CaptureFailureCategory.Storage
            ? "StatusStopToRecoverDurable"
            : "StatusStopToRecoverAudio");
    }

    private static string NormalizeLanguage(string? language) => language switch
    {
        "en" => "en",
        "fr" => "fr",
        _ => "es",
    };

    private static async Task<T?> ReadJsonAsync<T>(string path)
    {
        try
        {
            if (!IsReadableRegularFile(path))
            {
                return default;
            }

            await using var stream = File.OpenRead(path);
            return await JsonSerializer.DeserializeAsync<T>(stream, JsonOptions).ConfigureAwait(false);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        {
            return default;
        }
    }

    private static async Task<string?> ReadTextAsync(string path)
    {
        try
        {
            return IsReadableRegularFile(path) ? await File.ReadAllTextAsync(path).ConfigureAwait(false) : null;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private static async Task<string?> ReadLiveTextAsync(string folder)
    {
        try
        {
            var jsonPath = Path.Combine(folder, "live-transcript.json");
            if (IsReadableRegularFile(jsonPath))
            {
                await using var stream = File.OpenRead(jsonPath);
                using var document = await JsonDocument.ParseAsync(stream).ConfigureAwait(false);
                if (document.RootElement.TryGetProperty("text", out var text))
                {
                    return text.GetString();
                }
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        {
            // Fall back to the readable checkpoint below.
        }

        return await ReadTextAsync(Path.Combine(folder, "live-transcript.txt")).ConfigureAwait(false);
    }

    private static bool IsReadableRegularFile(string path)
    {
        try
        {
            if (!File.Exists(path))
            {
                return false;
            }

            var attributes = File.GetAttributes(path);
            return (attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) == 0
                && new FileInfo(path).Length <= MaximumReadableDocumentBytes;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    private async Task<IReadOnlyList<DiarizationSpan>> PrepareDiarizationAsync(
        string wavePath,
        IProgress<ModelDownloadProgress> progress,
        CancellationToken cancellationToken)
    {
        var models = await modelProvisioner.EnsureDiarizationAsync(progress, cancellationToken)
            .ConfigureAwait(false);
        return await DiarizationWorker.RunIsolatedAsync(wavePath, models, cancellationToken)
            .ConfigureAwait(false);
    }

    private static async Task ObserveFailureAsync(Task task)
    {
        try
        {
            await task.ConfigureAwait(false);
        }
        catch (Exception)
        {
            // Preserve the primary transcription failure after cancelling the worker.
        }
    }

    private static async Task IgnoreCancellationAsync(Task? task)
    {
        if (task is null)
        {
            return;
        }

        try
        {
            await task.ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            // Expected when a recording or window closes.
        }
        catch (Exception error)
        {
            // Live ASR and the elapsed indicator are secondary to the durable
            // capture. Their failure must never prevent Stop from finalizing WAV.
            CrashLog.Write(error);
        }
    }

    private static void RunOnUi(Action action)
    {
        var dispatcher = Application.Current?.Dispatcher;
        if (dispatcher is null || dispatcher.CheckAccess())
        {
            action();
        }
        else
        {
            _ = dispatcher.BeginInvoke(action);
        }
    }

    private static Task RunOnUiAsync(Action action)
    {
        var dispatcher = Application.Current?.Dispatcher;
        if (dispatcher is null || dispatcher.CheckAccess())
        {
            action();
            return Task.CompletedTask;
        }

        return dispatcher.InvokeAsync(action).Task;
    }
}
