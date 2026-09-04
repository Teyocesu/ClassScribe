using ClassScribe.Core;

namespace ClassScribe.Windows;

internal sealed class CaptureModeChoice : ObservableObject
{
    private string name;

    public CaptureModeChoice(CaptureMode value, string name)
    {
        Value = value;
        this.name = name;
    }

    public CaptureMode Value { get; }

    public string Name
    {
        get => name;
        private set => SetProperty(ref name, value);
    }

    public void Refresh(AppLocalization localization) =>
        Name = Value == CaptureMode.Online
            ? localization["CaptureModeOnline"]
            : localization["CaptureModeInPerson"];
}

internal sealed class LanguageChoice : ObservableObject
{
    private string name;

    public LanguageChoice(string code, string name)
    {
        Code = code;
        this.name = name;
    }

    public string Code { get; }

    public string Name
    {
        get => name;
        private set => SetProperty(ref name, value);
    }

    public void Refresh(AppLocalization localization) =>
        Name = Code switch
        {
            InterfaceLanguageCodes.Spanish => localization["LanguageSpanish"],
            InterfaceLanguageCodes.French => localization["LanguageFrench"],
            _ => localization["LanguageEnglish"],
        };
}

internal sealed class OnlineCaptureSourceChoice : ObservableObject
{
    private string name;

    public OnlineCaptureSourceChoice(OnlineCaptureSource value, string name)
    {
        Value = value;
        this.name = name;
    }

    public OnlineCaptureSource Value { get; }

    public string Name
    {
        get => name;
        private set => SetProperty(ref name, value);
    }

    public void Refresh(AppLocalization localization) =>
        Name = Value == OnlineCaptureSource.Application
            ? localization["OnlineSourceApplication"]
            : localization["OnlineSourceSystemOutput"];
}

internal sealed class SpeakerChoice : ObservableObject
{
    private readonly AppLocalization localization;

    public SpeakerChoice(SpeakerRecord model, AppLocalization localization)
    {
        Model = model;
        this.localization = localization;
    }

    public SpeakerRecord Model { get; }

    public string Id => Model.Id;

    public string DisplayName => SpeakerPresentation.LocalizedName(
        Model.Id,
        Model.DisplayName,
        localization);

    public void RefreshLocalization() => OnPropertyChanged(nameof(DisplayName));
}

internal sealed class ReviewRow : ObservableObject
{
    private readonly AppLocalization localization;
    private bool includeForProfessor;

    public ReviewRow(ReviewItem item, AppLocalization? localization = null)
    {
        Item = item;
        this.localization = localization ?? AppLocalization.Instance;
        includeForProfessor = item.ManuallyAssignedToProfessor;
    }

    public ReviewItem Item { get; }

    public string Time => Timecode.Display(Item.Segment.Start);

    public string Speaker => SpeakerPresentation.LocalizedName(
        Item.Segment.SpeakerID,
        storedDisplayName: null,
        localization);

    public string Reason => ReviewReasonPresentation.Localized(Item.Reason, localization);

    public string Text => Item.Segment.Text;

    public bool IncludeForProfessor
    {
        get => includeForProfessor;
        set => SetProperty(ref includeForProfessor, value);
    }

    public ReviewItem ToModel() => Item with { ManuallyAssignedToProfessor = IncludeForProfessor };

    public void RefreshLocalization()
    {
        OnPropertyChanged(nameof(Speaker));
        OnPropertyChanged(nameof(Reason));
    }
}

internal sealed class HistoryRow : ObservableObject
{
    private readonly AppLocalization localization;

    public HistoryRow(SessionSummary session, AppLocalization? localization = null)
    {
        Session = session;
        this.localization = localization ?? AppLocalization.Instance;
    }

    public SessionSummary Session { get; }

    public string Heading => string.IsNullOrWhiteSpace(Session.Metadata.Subject)
        ? localization["ClassWithoutName"]
        : Session.Metadata.Subject;

    public string Date => Session.Metadata.StartedAt.ToLocalTime()
        .ToString("g", localization.Culture);

    public string Detail => $"{Timecode.Display(Session.Metadata.Duration)} · "
        + (Session.IsRecoverable
            ? localization["HistoryRecoverable"]
            : ProcessingStatePresentation.Name(Session.Metadata.State, localization));

    public void RefreshLocalization()
    {
        OnPropertyChanged(nameof(Heading));
        OnPropertyChanged(nameof(Date));
        OnPropertyChanged(nameof(Detail));
    }
}

internal static class ProcessingStatePresentation
{
    public static string Name(ProcessingState state, AppLocalization localization) => state switch
    {
        ProcessingState.Ready => localization["StatusReady"],
        ProcessingState.StartingCapture => localization["StatusWaitingAudio"],
        ProcessingState.LoadingModel => localization["StatusPreparingBeforeRecording"],
        ProcessingState.Recording => localization["StatusRecording"],
        ProcessingState.TranscriptionPaused => localization["StatusRecordingPaused"],
        ProcessingState.Stopping => localization["StatusClosingAudio"],
        ProcessingState.FinalizingAudio => localization["StatusClosingAudio"],
        ProcessingState.FinalTranscription => localization["StatusFinalPreparing"],
        ProcessingState.Diarizing => localization["StatusFinalizingSpeakers"],
        ProcessingState.Complete => localization["StatusFinalReady"],
        ProcessingState.Cancelled => localization["StatusProcessCancelled"],
        ProcessingState.Failed => localization["StatusOperationFailed"],
        ProcessingState.Recoverable => localization["HistoryRecoverable"],
        _ => localization["StatusOperationFailed"],
    };
}
