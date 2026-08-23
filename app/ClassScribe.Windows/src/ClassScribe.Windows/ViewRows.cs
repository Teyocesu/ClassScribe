using ClassScribe.Core;

namespace ClassScribe.Windows;

internal sealed record CaptureModeChoice(CaptureMode Value, string Name);

internal sealed record LanguageChoice(string Code, string Name);

internal sealed class ReviewRow : ObservableObject
{
    private bool includeForProfessor;

    public ReviewRow(ReviewItem item)
    {
        Item = item;
        includeForProfessor = item.ManuallyAssignedToProfessor;
    }

    public ReviewItem Item { get; }

    public string Time => Timecode.Display(Item.Segment.Start);

    public string Speaker => Item.Segment.SpeakerID;

    public string Reason => Item.Reason;

    public string Text => Item.Segment.Text;

    public bool IncludeForProfessor
    {
        get => includeForProfessor;
        set => SetProperty(ref includeForProfessor, value);
    }

    public ReviewItem ToModel() => Item with { ManuallyAssignedToProfessor = IncludeForProfessor };
}

internal sealed record HistoryRow(SessionSummary Session)
{
    public string Heading => string.IsNullOrWhiteSpace(Session.Metadata.Subject)
        ? "Clase sin nombre"
        : Session.Metadata.Subject;

    public string Date => Session.Metadata.StartedAt.ToLocalTime()
        .ToString("g", System.Globalization.CultureInfo.CurrentCulture);

    public string Detail => $"{Timecode.Display(Session.Metadata.Duration)} · "
        + (Session.IsRecoverable ? "Recuperable" : Session.Metadata.State.ToSpanish());
}
