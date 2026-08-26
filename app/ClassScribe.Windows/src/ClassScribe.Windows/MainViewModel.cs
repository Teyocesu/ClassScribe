using System.Collections.ObjectModel;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Windows;
using ClassScribe.Core;

namespace ClassScribe.Windows;

internal sealed class MainViewModel : ObservableObject, IAsyncDisposable
{
    private const long MaximumReadableDocumentBytes = 64 * 1_024 * 1_024;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    private readonly SessionStore sessionStore;
    private readonly LocalModelProvisioner modelProvisioner = new();
    private readonly WindowsAudioCapture audioCapture;
    private readonly Func<bool> systemOutputConsentPrompt;
    private readonly WhisperTranscriber transcriber;
    private readonly List<TranscriptSegment> segments = [];
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
    private HistoryRow? selectedHistory;
    private SpeakerRecord? selectedProfessor;
    private ClassMetadata? currentMetadata;
    private string? currentFolder;
    private string subject = string.Empty;
    private string vocabulary = string.Empty;
    private string liveText = string.Empty;
    private string allText = string.Empty;
    private string professorText = string.Empty;
    private string automaticLiveText = string.Empty;
    private string statusText = "Lista para grabar";
    private string warningText = string.Empty;
    private string elapsedText = "00:00";
    private double audioLevel;
    private CaptureSignalState captureSignalState = CaptureSignalState.AwaitingCallbacks;
    private CaptureSignalState? lastPresentedCaptureSignalState;
    private double modelProgress;
    private bool isRecording;
    private bool isBusy;
    private bool isPaused;
    private bool liveWasEdited;
    private bool settingLiveProgrammatically;
    private bool disposed;
    private long attemptGeneration;
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
        Func<bool>? systemOutputConsentPrompt = null)
    {
        this.sessionStore = sessionStore ?? new SessionStore();
        this.audioCapture = audioCapture ?? new WindowsAudioCapture();
        this.systemOutputConsentPrompt = systemOutputConsentPrompt ?? (() => false);
        CaptureModes =
        [
            new CaptureModeChoice(CaptureMode.Online, "Clase online · audio de una aplicación"),
            new CaptureModeChoice(CaptureMode.InPerson, "Clase presencial · micrófono"),
        ];
        OnlineSourceChoices =
        [
            new OnlineCaptureSourceChoice(OnlineCaptureSource.Application, "Una aplicación"),
            new OnlineCaptureSourceChoice(OnlineCaptureSource.SystemOutput, "Audio del equipo"),
        ];
        Languages =
        [
            new LanguageChoice("es", "Español"),
            new LanguageChoice("en", "English"),
            new LanguageChoice("fr", "Français"),
        ];
        selectedMode = CaptureModes[0];
        selectedOnlineSource = OnlineSourceChoices[0];
        selectedLanguage = Languages[0];
        transcriber = new WhisperTranscriber(modelProvisioner);
    }

    public IReadOnlyList<CaptureModeChoice> CaptureModes { get; }

    public IReadOnlyList<OnlineCaptureSourceChoice> OnlineSourceChoices { get; }

    public IReadOnlyList<LanguageChoice> Languages { get; }

    public ObservableCollection<AudioSourceOption> Sources { get; } = [];

    public ObservableCollection<HistoryRow> History { get; } = [];

    public ObservableCollection<SpeakerRecord> Speakers { get; } = [];

    public ObservableCollection<ReviewRow> ReviewRows { get; } = [];

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

    public SpeakerRecord? SelectedProfessor
    {
        get => selectedProfessor;
        set => SetProperty(ref selectedProfessor, value);
    }

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
        get => statusText;
        private set => SetProperty(ref statusText, value);
    }

    public string WarningText
    {
        get => warningText;
        private set
        {
            if (SetProperty(ref warningText, value))
            {
                OnPropertyChanged(nameof(HasWarning));
            }
        }
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

    public string PauseButtonText => IsPaused ? "Reanudar texto" : "Pausar texto";

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
        ? "Todavía no hay una sesión abierta"
        : Path.GetFileName(currentFolder);

    public bool CanReprocess => !IsBusy
        && !IsRecording
        && currentFolder is not null
        && (File.Exists(Path.Combine(currentFolder, "source.wav"))
            || File.Exists(Path.Combine(currentFolder, "source.raw")));

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
            StatusText = "Audio del equipo listo para grabar";
            NotifyAvailability();
            return;
        }

        StatusText = mode == CaptureMode.Online
            ? "Buscando aplicaciones abiertas…"
            : "Buscando micrófonos…";
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
            StatusText = Sources.Count == 0
                ? mode == CaptureMode.Online
                    ? "No hay aplicaciones con ventana abierta"
                    : "No se encontraron micrófonos activos"
                : "Lista para grabar";
        }
        catch (Exception error) when (error is InvalidOperationException
                                           or System.ComponentModel.Win32Exception
                                           or UnauthorizedAccessException)
        {
            Sources.Clear();
            SelectedSource = null;
            WarningText = $"No se pudieron leer las fuentes de audio: {error.Message}";
            StatusText = "Revisa los permisos de micrófono de Windows";
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
            WarningText = "Completa la materia y selecciona una fuente de audio.";
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
            ? new AudioSourceOption(AudioSourceKind.SystemOutput, "system-output", "Audio del equipo")
            : SelectedSource;
        if (source is null)
        {
            WarningText = "Completa la materia y selecciona una fuente de audio.";
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
                StatusText = "Captura del audio del equipo cancelada.";
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
        Speakers.Clear();
        ReviewRows.Clear();
        SelectedProfessor = null;
        automaticLiveText = string.Empty;
        liveWasEdited = false;
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

            StatusText = "Esperando el primer callback de audio…";
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
                StatusText = "Grabando y guardando audio localmente";
            }
            StartBackgroundLoops();
        }
        catch (OperationCanceledException)
        {
            if (!IsCurrent(attempt))
            {
                return;
            }

            StatusText = "Inicio cancelado; cualquier audio recibido quedó guardado";
            await MarkCurrentStateAsync(ProcessingState.Cancelled, attempt).ConfigureAwait(true);
        }
        catch (Exception error)
        {
            if (!IsCurrent(attempt))
            {
                return;
            }

            if (captureStartInvoked
                && captureScope == CaptureScope.Application
                && audioCapture.LastStartFailureCategory == CaptureFailureCategory.Source)
            {
                captureRecoverySuggestion = CaptureRecoverySuggestion.SystemOutput;
                OnPropertyChanged(nameof(ShowSystemOutputRecovery));
            }
            WarningText = error.Message;
            StatusText = "No se pudo iniciar la grabación";
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
        StatusText = IsPaused
            ? "Grabando audio · transcripción en vivo pausada"
            : "Grabando y transcribiendo";
    }

    public Task StopAsync() => StopAsync(processAfterStop: true);

    public Task StopForExitAsync() => StopAsync(processAfterStop: false);

    private async Task StopAsync(bool processAfterStop)
    {
        if (!CanStop)
        {
            return;
        }

        var operation = BeginOperation();
        var attempt = activeAttempt;
        IsBusy = true;
        IsPaused = false;
        WarningText = string.Empty;
        StatusText = "Cerrando y validando el audio…";
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
                await ProcessWaveAsync(wavePath, processingCancellation.Token).ConfigureAwait(true);
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

                StatusText = "Audio y texto guardados para reprocesar en el próximo inicio";
            }
        }
        catch (OperationCanceledException)
        {
            if (!IsCurrent(attempt))
            {
                return;
            }

            IsRecording = false;
            StatusText = "Procesamiento cancelado; la grabación y el texto parcial se conservaron";
            await MarkCurrentStateAsync(ProcessingState.Cancelled, attempt).ConfigureAwait(true);
        }
        catch (Exception error)
        {
            if (!IsCurrent(attempt))
            {
                return;
            }

            IsRecording = false;
            WarningText = error.Message;
            StatusText = "La sesión quedó guardada para reintentar";
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
            StatusText = "Captura del audio del equipo cancelada.";
            return;
        }

        processingCancellation?.Cancel();
        StatusText = "Cancelando de forma segura…";
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
            WarningText = "Esta sesión no conserva audio suficiente para reprocesar.";
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

            StatusText = "Reprocesado cancelado; los archivos existentes no cambiaron";
            await MarkCurrentStateAsync(ProcessingState.Cancelled, attempt).ConfigureAwait(true);
        }
        catch (Exception error)
        {
            if (!IsCurrent(attempt))
            {
                return;
            }

            WarningText = error.Message;
            StatusText = "No se pudo reprocesar; los archivos anteriores siguen disponibles";
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
        ProfessorText = TranscriptExporter.PlainText(professor);
        metadata = metadata with
        {
            ProfessorSpeakerID = selectedProfessorID,
            ProfessorSelectionIsAutomatic = false,
            State = ProcessingState.Complete,
            SessionPhase = ClassScribe.Core.SessionPhase.Complete,
            CapturePhase = ClassScribe.Core.CapturePhase.Idle,
            AsrPhase = ClassScribe.Core.AsrPhase.Idle,
        };
        var humanCorrection = new HumanCorrectionUpdate
        {
            Operations =
            [
                new SpeakerCorrectionOperation
                {
                    Id = Guid.NewGuid(),
                    Kind = SpeakerCorrectionKind.ProfessorConfirmation,
                    SpeakerID = selectedProfessorID,
                    SegmentIDs = [],
                    CreatedAt = DateTimeOffset.UtcNow,
                },
            ],
        };
        var speakers = Speakers.ToArray();
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
        ApplyActiveHumanCorrection();

        StatusText = "Selección de profesor guardada";
    }

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
            var speakers = Speakers.ToArray();
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
        StatusText = "Cambios guardados";
        await RefreshHistoryAsync(attempt).ConfigureAwait(true);
    }

    public string ChatEnvelope() => currentMetadata is null
        ? AllText
        : TranscriptActions.ChatEnvelope(
            currentMetadata.Subject,
            currentMetadata.StartedAt,
            currentMetadata.Duration,
            currentMetadata.Mode,
            currentMetadata.Source,
            TranscriptActions.BestAvailable(ProfessorText, AllText, LiveText));

    public string? CurrentFolder => currentFolder;

    public DateTimeOffset CurrentStartedAt => currentMetadata?.StartedAt ?? DateTimeOffset.Now;

    public async ValueTask DisposeAsync()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
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
        WarningText = error.Message;
        StatusText = "La operación no pudo completarse";
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
        await Task.Delay(TimeSpan.FromSeconds(6), cancellationToken).ConfigureAwait(false);
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
                    var pcm = audioCapture.Snapshot(TimeSpan.FromSeconds(25));
                    if (pcm.Length >= PcmWaveFile.SampleRate * 2)
                    {
                        var duration = audioCapture.DurationSeconds;
                        var offset = Math.Max(0, duration - (pcm.Length / 32_000d));
                        var progress = new Progress<ModelDownloadProgress>(
                            value => UpdateModelProgress(value, attempt));
                        var sessionVocabulary = currentMetadata?.TechnicalVocabulary ?? string.Empty;
                        var sessionLanguage = NormalizeLanguage(currentMetadata?.Language);
                        var provisional = await transcriber.TranscribePcmAsync(
                                pcm,
                                sessionVocabulary,
                                sessionLanguage,
                                offset,
                                progress,
                            cancellationToken)
                            .ConfigureAwait(false);
                        if (!IsCurrent(attempt))
                        {
                            break;
                        }

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
                        if (IsCurrent(attempt))
                        {
                            WarningText = $"El texto en vivo se reintentará: {error.Message}";
                            StatusText = "El audio sigue grabándose de forma segura";
                        }
                    });
                }
            }

            await Task.Delay(TimeSpan.FromSeconds(9), cancellationToken).ConfigureAwait(false);
        }
    }

    private async Task ProcessWaveAsync(string wavePath, CancellationToken cancellationToken)
    {
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

        StatusText = "Transcribiendo toda la clase con máxima calidad…";
        ModelProgress = 0;
        var progress = new Progress<ModelDownloadProgress>(
            value => UpdateModelProgress(value, attempt));
        var finalSegments = await transcriber.TranscribeFileAsync(
                wavePath,
                currentMetadata.TechnicalVocabulary,
                NormalizeLanguage(currentMetadata.Language),
                progress,
            cancellationToken)
            .ConfigureAwait(true);
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
        AllText = TranscriptExporter.PlainText(segments);
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

        // Commit the complete transcript before invoking any native diarization code.
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

        ApplyActiveHumanCorrection();

        IReadOnlyList<TranscriptSegment> assigned = segments.ToArray();
        IReadOnlyList<ReviewItem> review = [];
        IReadOnlyList<SpeakerRecord> speakers = [];
        string? diarizationWarning = null;
        try
        {
            StatusText = "Preparando e identificando hablantes…";
            var diarizationModels = await modelProvisioner.EnsureDiarizationAsync(progress, cancellationToken)
                .ConfigureAwait(true);
            if (!IsCurrent(attempt))
            {
                return;
            }

            var spans = await DiarizationWorker.RunIsolatedAsync(
                    wavePath,
                    diarizationModels,
                cancellationToken)
                .ConfigureAwait(true);
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
        var professorId = humanProfessorSelection
            ? humanProfessorSpeakerID
            : SpeakerAssignment.ProvisionalProfessor(speakers);
        var professor = SpeakerAssignment.ProfessorSegments(segments, professorId, review);
        AllText = TranscriptExporter.PlainText(segments);
        ProfessorText = TranscriptExporter.PlainText(professor);
        Speakers.Clear();
        foreach (var speaker in speakers)
        {
            Speakers.Add(speaker);
        }

        ReviewRows.Clear();
        foreach (var item in review)
        {
            ReviewRows.Add(new ReviewRow(item));
        }

        SelectedProfessor = Speakers.FirstOrDefault(speaker => speaker.Id == professorId);
        currentMetadata = currentMetadata with
        {
            State = ProcessingState.Complete,
            SessionPhase = ClassScribe.Core.SessionPhase.Complete,
            CapturePhase = ClassScribe.Core.CapturePhase.Idle,
            AsrPhase = ClassScribe.Core.AsrPhase.Idle,
            SpeakerCount = Speakers.Count,
            ProfessorSpeakerID = professorId,
            ProfessorSelectionIsAutomatic = !humanProfessorSelection,
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

        ApplyActiveHumanCorrection();

        ModelProgress = 1;
        if (diarizationWarning is null)
        {
            WarningText = string.Empty;
            StatusText = "Transcripción final lista";
        }
        else
        {
            WarningText = $"La transcripción está completa, pero faltó separar hablantes: {diarizationWarning}";
            StatusText = "Transcripción lista para editar o reprocesar";
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

            segments.Clear();
            segments.AddRange(loadedSegments);
            activeHumanCorrectionOverlay = loadedOverlay;
            AllText = loadedOverlay?.EditedAllText ?? TranscriptActions.BestAvailable(
                loadedAll,
                loadedSegments.Length > 0 ? TranscriptExporter.PlainText(loadedSegments) : null,
                loadedLive);
            ProfessorText = loadedOverlay?.EditedProfessorText ?? loadedProfessor ?? string.Empty;
            SetLiveProgrammatically(loadedLive ?? string.Empty);
            Speakers.Clear();
            foreach (var speaker in loadedSpeakers)
            {
                Speakers.Add(speaker);
            }

            ReviewRows.Clear();
            foreach (var item in loadedReview)
            {
                ReviewRows.Add(new ReviewRow(item));
            }

            SelectedProfessor = Speakers.FirstOrDefault(speaker =>
                speaker.Id == summary.Metadata.ProfessorSpeakerID);
            captureRecoverySuggestion = null;
            OnPropertyChanged(nameof(ShowSystemOutputRecovery));
            WarningText = summary.RecoveryReason ?? string.Empty;
            StatusText = summary.IsRecoverable ? "Sesión recuperable abierta" : "Sesión abierta";
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
            History.Add(new HistoryRow(session));
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

        StatusText = IsPaused ? "Grabando · texto en vivo pausado" : "Grabando y transcribiendo";
        WarningText = string.Empty;
    }

    private void ApplyCaptureSignal(CaptureSignalHealthSnapshot snapshot, SessionAttemptID attempt)
    {
        if (!IsCurrent(attempt))
        {
            return;
        }

        SignalState = snapshot.State;
        if (!CaptureSignalPresentationPolicy.ShouldPresent(
                snapshot.State,
                lastPresentedCaptureSignalState,
                IsRecording))
        {
            return;
        }

        lastPresentedCaptureSignalState = snapshot.State;
        StatusText = snapshot.State switch
        {
            CaptureSignalState.AwaitingCallbacks => "Esperando callbacks de audio…",
            CaptureSignalState.NoCallbacks => "La fuente dejó de entregar callbacks; conserva el audio recibido y revisa la fuente.",
            CaptureSignalState.Silent => "Captura activa con callbacks silenciosos; el silencio no es un fallo.",
            CaptureSignalState.Audible => "Audio recibido; esperando voz o un resultado de transcripción.",
            _ => StatusText,
        };
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
            StatusText = progress.ReceivedBytes < progress.TotalBytes
                ? $"Descargando {progress.Name}: {progress.Fraction:P0}"
                : $"{progress.Name} listo";
        });
    }

    private void ApplyActiveHumanCorrection()
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
            EditedAllText = correction.AllText ?? existing.EditedAllText,
            EditedProfessorText = correction.ProfessorText ?? existing.EditedProfessorText,
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

            lease.TryAccept(() => RunOnUi(() => lease.TryAccept(() =>
            {
                if (fault.Category == CaptureFailureCategory.Source
                    && currentMetadata?.CaptureScope == CaptureScope.Application)
                {
                    captureRecoverySuggestion = CaptureRecoverySuggestion.SystemOutput;
                    OnPropertyChanged(nameof(ShowSystemOutputRecovery));
                }

                WarningText = $"La fuente de audio se interrumpió: {fault.Error.Message}";
                StatusText = "Detén la sesión para validar y recuperar el audio recibido";
            })));
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
        StatusText = "Audio del equipo seleccionado. Presiona Iniciar grabación para continuar.";
    }

    private bool IsCurrent(SessionAttemptID? attempt) =>
        attempt is not null && activeAttempt == attempt;

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
