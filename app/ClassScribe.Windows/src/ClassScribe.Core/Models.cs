using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ClassScribe.Core;

[JsonConverter(typeof(CaptureModeJsonConverter))]
public enum CaptureMode
{
    Online,
    InPerson,
}

[JsonConverter(typeof(ProcessingStateJsonConverter))]
public enum ProcessingState
{
    Ready,
    StartingCapture,
    LoadingModel,
    Recording,
    TranscriptionPaused,
    Stopping,
    FinalizingAudio,
    FinalTranscription,
    Diarizing,
    Complete,
    Cancelled,
    Failed,
    Recoverable,
}

public sealed record TranscriptSegment
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public double Start { get; init; }
    public double End { get; init; }
    public string Text { get; init; } = string.Empty;
    public string SpeakerID { get; init; } = "Persona desconocida";
    public double Confidence { get; init; }
    public bool Provisional { get; init; }
    public bool OverlappingVoices { get; init; }
}

public sealed record DiarizationSpan
{
    public double Start { get; init; }
    public double End { get; init; }
    public string SpeakerID { get; init; } = string.Empty;
    public double Quality { get; init; }
}

public sealed record SpeakerRecord
{
    public string Id { get; init; } = string.Empty;
    public string DisplayName { get; init; } = string.Empty;
    public double TotalSpeakingTime { get; init; }
    public IReadOnlyList<string> RecentFragments { get; init; } = [];
    public double Confidence { get; init; }
    public float[]? Embedding { get; init; }
}

public sealed record ReviewItem
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public required TranscriptSegment Segment { get; init; }
    public string Reason { get; init; } = string.Empty;
    public bool ManuallyAssignedToProfessor { get; init; }
}

[JsonConverter(typeof(ClassMetadataJsonConverter))]
public sealed record ClassMetadata
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public string Subject { get; init; } = string.Empty;
    public DateTimeOffset StartedAt { get; init; } = DateTimeOffset.Now;
    public double Duration { get; init; }
    public CaptureMode Mode { get; init; }
    public string Source { get; init; } = string.Empty;
    public string? ProfessorSpeakerID { get; init; }
    public bool ProfessorSelectionIsAutomatic { get; init; } = true;
    public int SpeakerCount { get; init; }
    public ProcessingState State { get; init; } = ProcessingState.Ready;
    public string FolderPath { get; init; } = string.Empty;
    public string TechnicalVocabulary { get; init; } = string.Empty;
    public string Language { get; init; } = "es";
    public string AudioFormat { get; init; } = PcmWaveFile.AudioFormatName;
    public string Platform { get; init; } = "windows";
    public int SchemaVersion { get; init; } = 2;
    public CaptureScope? CaptureScope { get; init; }
    public SessionPhase? SessionPhase { get; init; }
    public CapturePhase? CapturePhase { get; init; }
    public AsrPhase? AsrPhase { get; init; }
    public int FormatVersion { get; init; } = 1;
    public SessionAttemptID? AttemptID { get; init; }
    public ASRTranscriptReference? AsrOriginalReference { get; init; }
    public IReadOnlyList<DiarizationProposalReference> DiarizationProposalReferences { get; init; } = [];
    public HumanCorrectionOverlayReference? HumanCorrectionOverlayReference { get; init; }
}

public static class CaptureModeText
{
    public static string ToSpanish(this CaptureMode mode) => mode switch
    {
        CaptureMode.Online => "Clase online",
        CaptureMode.InPerson => "Clase presencial",
        _ => throw new ArgumentOutOfRangeException(nameof(mode)),
    };

    public static CaptureMode Parse(string value) => value.Trim().ToLowerInvariant() switch
    {
        "clase online" or "online" or "application" => CaptureMode.Online,
        "clase presencial" or "inperson" or "in_person" or "in person" or "microphone" => CaptureMode.InPerson,
        "systemoutput" or "system_output" or "system output" => CaptureMode.Online,
        _ => throw new JsonException($"Modo de captura desconocido: {value}"),
    };

    public static string ToPersistentToken(this CaptureMode mode) => mode switch
    {
        CaptureMode.Online => "online",
        CaptureMode.InPerson => "inPerson",
        _ => throw new ArgumentOutOfRangeException(nameof(mode)),
    };

    public static CaptureScope ToScope(this CaptureMode mode) => mode switch
    {
        CaptureMode.Online => CaptureScope.Application,
        CaptureMode.InPerson => CaptureScope.Microphone,
        _ => throw new ArgumentOutOfRangeException(nameof(mode)),
    };
}

public static class ProcessingStateText
{
    public static string ToSpanish(this ProcessingState state) => state switch
    {
        ProcessingState.Ready => "Lista",
        ProcessingState.StartingCapture => "Esperando audio de la fuente",
        ProcessingState.LoadingModel => "Preparando transcripción",
        ProcessingState.Recording => "Grabando",
        ProcessingState.TranscriptionPaused => "Grabando · transcripción pausada",
        ProcessingState.Stopping => "Guardando transcripción",
        ProcessingState.FinalizingAudio => "Validando audio",
        ProcessingState.FinalTranscription => "Retranscribiendo con máxima calidad",
        ProcessingState.Diarizing => "Identificando hablantes",
        ProcessingState.Complete => "Transcripción final lista",
        ProcessingState.Cancelled => "Procesamiento cancelado",
        ProcessingState.Failed => "Error",
        ProcessingState.Recoverable => "Sesión recuperable",
        _ => throw new ArgumentOutOfRangeException(nameof(state)),
    };

    public static ProcessingState Parse(string value)
    {
        foreach (var state in Enum.GetValues<ProcessingState>())
        {
            if (string.Equals(state.ToSpanish(), value, StringComparison.Ordinal)
                || string.Equals(state.ToToken(), value, StringComparison.OrdinalIgnoreCase)
                || string.Equals(state.ToString(), value, StringComparison.OrdinalIgnoreCase))
            {
                return state;
            }
        }

        throw new JsonException($"Estado desconocido: {value}");
    }

    public static string ToToken(this ProcessingState state) => state switch
    {
        ProcessingState.Ready => "ready",
        ProcessingState.StartingCapture => "startingCapture",
        ProcessingState.LoadingModel => "loadingModel",
        ProcessingState.Recording => "recording",
        ProcessingState.TranscriptionPaused => "transcriptionPaused",
        ProcessingState.Stopping => "stopping",
        ProcessingState.FinalizingAudio => "finalizingAudio",
        ProcessingState.FinalTranscription => "finalTranscription",
        ProcessingState.Diarizing => "diarizing",
        ProcessingState.Complete => "complete",
        ProcessingState.Cancelled => "cancelled",
        ProcessingState.Failed => "failed",
        ProcessingState.Recoverable => "recoverable",
        _ => throw new ArgumentOutOfRangeException(nameof(state)),
    };
}

public static class Timecode
{
    public static string Display(double seconds)
    {
        var total = SafeMilliseconds(seconds) / 1_000;
        var hours = total / 3_600;
        var minutes = (total / 60) % 60;
        var remainingSeconds = total % 60;
        return hours > 0
            ? $"{hours}:{minutes:00}:{remainingSeconds:00}"
            : $"{minutes:00}:{remainingSeconds:00}";
    }

    public static string Srt(double seconds)
    {
        var milliseconds = SafeMilliseconds(seconds);
        return $"{milliseconds / 3_600_000:00}:{(milliseconds / 60_000) % 60:00}:"
            + $"{(milliseconds / 1_000) % 60:00},{milliseconds % 1_000:000}";
    }

    private static long SafeMilliseconds(double seconds)
    {
        if (!double.IsFinite(seconds) || seconds <= 0)
        {
            return 0;
        }

        var milliseconds = Math.Round(seconds * 1_000, MidpointRounding.AwayFromZero);
        return milliseconds >= long.MaxValue ? long.MaxValue : (long)milliseconds;
    }
}

public static class FilenameSlug
{
    private static readonly HashSet<string> ReservedNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    };

    public static string Create(string value, int maximumUtf8Bytes = 120)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(maximumUtf8Bytes);
        var normalized = value.Normalize(NormalizationForm.FormC).ToLower(new CultureInfo("es"));
        var builder = new StringBuilder();
        var needsSeparator = false;

        foreach (var rune in normalized.EnumerateRunes())
        {
            if (Rune.IsLetterOrDigit(rune))
            {
                if (needsSeparator && builder.Length > 0)
                {
                    AppendIfFits(builder, "-", maximumUtf8Bytes);
                }

                if (!AppendIfFits(builder, rune.ToString(), maximumUtf8Bytes))
                {
                    break;
                }

                needsSeparator = false;
            }
            else
            {
                needsSeparator = builder.Length > 0;
            }
        }

        var result = builder.ToString().Trim('-');
        return ReservedNames.Contains(result) ? $"clase-{result}" : result;
    }

    private static bool AppendIfFits(StringBuilder builder, string value, int maximumUtf8Bytes)
    {
        if (Encoding.UTF8.GetByteCount(builder.ToString()) + Encoding.UTF8.GetByteCount(value) > maximumUtf8Bytes)
        {
            return false;
        }

        builder.Append(value);
        return true;
    }
}

internal sealed class CaptureModeJsonConverter : JsonConverter<CaptureMode>
{
    public override CaptureMode Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        CaptureModeText.Parse(reader.GetString() ?? string.Empty);

    public override void Write(Utf8JsonWriter writer, CaptureMode value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToPersistentToken());
}

internal sealed class ProcessingStateJsonConverter : JsonConverter<ProcessingState>
{
    public override ProcessingState Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        ProcessingStateText.Parse(reader.GetString() ?? string.Empty);

    public override void Write(Utf8JsonWriter writer, ProcessingState value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToToken());
}
