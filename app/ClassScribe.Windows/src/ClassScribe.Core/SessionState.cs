using System.Text.Json;
using System.Text.Json.Serialization;

namespace ClassScribe.Core;

/// Stable identity for one start/session attempt. A result is accepted only
/// when the complete value still matches the active attempt.
public sealed record SessionAttemptID
{
    [JsonPropertyName("sessionID")]
    public Guid SessionID { get; init; }

    [JsonPropertyName("generation")]
    public long Generation { get; init; }

    [JsonPropertyName("nonce")]
    public Guid Nonce { get; init; }

    [JsonIgnore]
    public string Token => $"{SessionID:D}:{Generation}:{Nonce:D}";

    public static SessionAttemptID Create(Guid sessionID, long generation) => new()
    {
        SessionID = sessionID,
        Generation = generation,
        Nonce = Guid.NewGuid(),
    };
}

/// Identifies a callback as belonging to one concrete capture attempt. The
/// lease is the ownership boundary used by UI event handlers: an event from a
/// previous attempt is rejected before it can be scheduled on the UI thread.
public sealed class SessionAttemptCallbackLease
{
    private readonly Func<SessionAttemptID, bool> isCurrent;
    private int revoked;

    public SessionAttemptCallbackLease(
        SessionAttemptID attempt,
        Func<SessionAttemptID, bool> isCurrent)
    {
        Attempt = attempt ?? throw new ArgumentNullException(nameof(attempt));
        this.isCurrent = isCurrent ?? throw new ArgumentNullException(nameof(isCurrent));
    }

    public SessionAttemptID Attempt { get; }

    public void Revoke() => Interlocked.Exchange(ref revoked, 1);

    public bool TryAccept(Action callback)
    {
        ArgumentNullException.ThrowIfNull(callback);
        if (Volatile.Read(ref revoked) != 0 || !isCurrent(Attempt))
        {
            return false;
        }

        callback();
        return true;
    }
}

[JsonConverter(typeof(CaptureScopeJsonConverter))]
public enum CaptureScope
{
    Microphone,
    Application,
    SystemOutput,
}

[JsonConverter(typeof(CapturePhaseJsonConverter))]
public enum CapturePhase
{
    Idle,
    ValidatingSource,
    Connecting,
    WaitingForFrames,
    FramesSilent,
    AudioAudible,
    Recording,
    Stopping,
    FailedRecoverable,
    FailedTerminal,
}

[JsonConverter(typeof(AsrPhaseJsonConverter))]
public enum AsrPhase
{
    Idle,
    PreparingDownload,
    PreparingLoad,
    WaitingForSpeech,
    Transcribing,
    RetryScheduled,
    UnavailableForSession,
    FailedRecoverable,
}

[JsonConverter(typeof(SessionPhaseJsonConverter))]
public enum SessionPhase
{
    Draft,
    Starting,
    Recording,
    Stopping,
    Processing,
    Complete,
    Cancelled,
    Recoverable,
    Failed,
}

public static class CaptureScopeText
{
    public static string ToToken(this CaptureScope scope) => scope switch
    {
        CaptureScope.Microphone => "microphone",
        CaptureScope.Application => "application",
        CaptureScope.SystemOutput => "systemOutput",
        _ => throw new ArgumentOutOfRangeException(nameof(scope)),
    };

    public static bool TryParse(string value, out CaptureScope scope)
    {
        switch (value.Trim().ToLowerInvariant())
        {
            case "microphone":
            case "inperson":
            case "in_person":
            case "in person":
            case "clase presencial":
                scope = CaptureScope.Microphone;
                return true;
            case "application":
            case "online":
            case "clase online":
                scope = CaptureScope.Application;
                return true;
            case "systemoutput":
            case "system_output":
            case "system output":
                scope = CaptureScope.SystemOutput;
                return true;
            default:
                scope = default;
                return false;
        }
    }
}

public static class CapturePhaseText
{
    public static string ToToken(this CapturePhase phase) => phase switch
    {
        CapturePhase.Idle => "idle",
        CapturePhase.ValidatingSource => "validatingSource",
        CapturePhase.Connecting => "connecting",
        CapturePhase.WaitingForFrames => "waitingForFrames",
        CapturePhase.FramesSilent => "framesSilent",
        CapturePhase.AudioAudible => "audioAudible",
        CapturePhase.Recording => "recording",
        CapturePhase.Stopping => "stopping",
        CapturePhase.FailedRecoverable => "failedRecoverable",
        CapturePhase.FailedTerminal => "failedTerminal",
        _ => throw new ArgumentOutOfRangeException(nameof(phase)),
    };

    public static bool TryParse(string value, out CapturePhase phase)
    {
        var token = value.Trim().ToLowerInvariant();
        foreach (var candidate in Enum.GetValues<CapturePhase>())
        {
            if (string.Equals(candidate.ToToken(), token, StringComparison.OrdinalIgnoreCase))
            {
                phase = candidate;
                return true;
            }
        }

        phase = default;
        return false;
    }
}

public static class AsrPhaseText
{
    public static string ToToken(this AsrPhase phase) => phase switch
    {
        AsrPhase.Idle => "idle",
        AsrPhase.PreparingDownload => "preparingDownload",
        AsrPhase.PreparingLoad => "preparingLoad",
        AsrPhase.WaitingForSpeech => "waitingForSpeech",
        AsrPhase.Transcribing => "transcribing",
        AsrPhase.RetryScheduled => "retryScheduled",
        AsrPhase.UnavailableForSession => "unavailableForSession",
        AsrPhase.FailedRecoverable => "failedRecoverable",
        _ => throw new ArgumentOutOfRangeException(nameof(phase)),
    };

    public static bool TryParse(string value, out AsrPhase phase)
    {
        var token = value.Trim().ToLowerInvariant();
        foreach (var candidate in Enum.GetValues<AsrPhase>())
        {
            if (string.Equals(candidate.ToToken(), token, StringComparison.OrdinalIgnoreCase))
            {
                phase = candidate;
                return true;
            }
        }

        phase = default;
        return false;
    }
}

public static class SessionPhaseText
{
    public static string ToToken(this SessionPhase phase) => phase switch
    {
        SessionPhase.Draft => "draft",
        SessionPhase.Starting => "starting",
        SessionPhase.Recording => "recording",
        SessionPhase.Stopping => "stopping",
        SessionPhase.Processing => "processing",
        SessionPhase.Complete => "complete",
        SessionPhase.Cancelled => "cancelled",
        SessionPhase.Recoverable => "recoverable",
        SessionPhase.Failed => "failed",
        _ => throw new ArgumentOutOfRangeException(nameof(phase)),
    };

    public static bool TryParse(string value, out SessionPhase phase)
    {
        var token = value.Trim().ToLowerInvariant();
        phase = token switch
        {
            "draft" or "ready" or "lista" => SessionPhase.Draft,
            "starting" or "startingcapture" or "esperando audio de la fuente" or "preparando transcripción" => SessionPhase.Starting,
            "recording" or "grabando" or "grabando · transcripción pausada" => SessionPhase.Recording,
            "stopping" or "guardando transcripción" or "validando audio" => SessionPhase.Stopping,
            "processing" or "finaltranscription" or "diarizing" or "retranscribiendo con máxima calidad" or "identificando hablantes" => SessionPhase.Processing,
            "complete" or "transcripción final lista" => SessionPhase.Complete,
            "cancelled" or "canceled" or "procesamiento cancelado" => SessionPhase.Cancelled,
            "recoverable" or "sesión recuperable" => SessionPhase.Recoverable,
            "failed" or "error" => SessionPhase.Failed,
            _ => default,
        };
        return token is "draft" or "ready" or "lista"
            or "starting" or "startingcapture" or "esperando audio de la fuente" or "preparando transcripción"
            or "recording" or "grabando" or "grabando · transcripción pausada"
            or "stopping" or "guardando transcripción" or "validando audio"
            or "processing" or "finaltranscription" or "diarizing" or "retranscribiendo con máxima calidad" or "identificando hablantes"
            or "complete" or "transcripción final lista"
            or "cancelled" or "canceled" or "procesamiento cancelado"
            or "recoverable" or "sesión recuperable"
            or "failed" or "error";
    }
}

public static class ProcessingStateAxes
{
    public static SessionPhase ToSessionPhase(this ProcessingState state) => state switch
    {
        ProcessingState.Ready => SessionPhase.Draft,
        ProcessingState.StartingCapture or ProcessingState.LoadingModel => SessionPhase.Starting,
        ProcessingState.Recording or ProcessingState.TranscriptionPaused => SessionPhase.Recording,
        ProcessingState.Stopping or ProcessingState.FinalizingAudio => SessionPhase.Stopping,
        ProcessingState.FinalTranscription or ProcessingState.Diarizing => SessionPhase.Processing,
        ProcessingState.Complete => SessionPhase.Complete,
        ProcessingState.Cancelled => SessionPhase.Cancelled,
        ProcessingState.Recoverable => SessionPhase.Recoverable,
        ProcessingState.Failed => SessionPhase.Failed,
        _ => SessionPhase.Failed,
    };

    public static CapturePhase ToCapturePhase(this ProcessingState state) => state switch
    {
        ProcessingState.Ready => CapturePhase.Idle,
        ProcessingState.StartingCapture => CapturePhase.Connecting,
        ProcessingState.LoadingModel or ProcessingState.Recording or ProcessingState.TranscriptionPaused => CapturePhase.Recording,
        ProcessingState.Stopping or ProcessingState.FinalizingAudio => CapturePhase.Stopping,
        ProcessingState.FinalTranscription or ProcessingState.Diarizing or ProcessingState.Complete or ProcessingState.Cancelled => CapturePhase.Idle,
        ProcessingState.Recoverable => CapturePhase.FailedRecoverable,
        ProcessingState.Failed => CapturePhase.FailedTerminal,
        _ => CapturePhase.FailedTerminal,
    };

    public static AsrPhase ToAsrPhase(this ProcessingState state) => state switch
    {
        ProcessingState.Ready or ProcessingState.StartingCapture => AsrPhase.Idle,
        ProcessingState.LoadingModel or ProcessingState.FinalTranscription => AsrPhase.PreparingLoad,
        ProcessingState.Recording or ProcessingState.TranscriptionPaused => AsrPhase.WaitingForSpeech,
        ProcessingState.Stopping or ProcessingState.Diarizing or ProcessingState.Complete or ProcessingState.Cancelled => AsrPhase.Idle,
        ProcessingState.Recoverable or ProcessingState.Failed => AsrPhase.FailedRecoverable,
        _ => AsrPhase.FailedRecoverable,
    };
}

public sealed record AudioFormatMetadata
{
    public int FormatVersion { get; init; } = 1;
    public string? Master { get; init; }
    public string? Asr { get; init; }
}

public sealed record AudioManifestReference
{
    [JsonPropertyName("relativePath")]
    public string RelativePath { get; init; } = "audio-manifest.json";
}

public sealed record ASRTranscriptReference
{
    [JsonPropertyName("runID")]
    public Guid RunID { get; init; }

    [JsonPropertyName("relativePath")]
    public string RelativePath { get; init; } = string.Empty;

    [JsonPropertyName("language")]
    public string Language { get; init; } = "es";

    [JsonPropertyName("attemptID")]
    public SessionAttemptID? AttemptID { get; init; }
}

public sealed record ASRTranscriptArtifact
{
    public int SchemaVersion { get; init; } = 1;
    public Guid RunID { get; init; }
    public DateTimeOffset CreatedAt { get; init; }
    public string Language { get; init; } = "es";
    public SessionAttemptID? AttemptID { get; init; }
    public IReadOnlyList<TranscriptSegment> Segments { get; init; } = [];
}

public sealed record DiarizationProposalReference
{
    public Guid ProposalID { get; init; }
    public string RelativePath { get; init; } = string.Empty;
}

public sealed record DiarizationProposal
{
    public int SchemaVersion { get; init; } = 1;
    public Guid ProposalID { get; init; }
    public DateTimeOffset CreatedAt { get; init; }
    public string? EngineVersion { get; init; }
    public Guid? AsrRunID { get; init; }
    public IReadOnlyList<DiarizationSpan> Spans { get; init; } = [];
}

public sealed record DiarizationProposalDocument
{
    public int SchemaVersion { get; init; } = 1;
    public IReadOnlyList<DiarizationProposal> Proposals { get; init; } = [];
}

[JsonConverter(typeof(SpeakerCorrectionKindJsonConverter))]
public enum SpeakerCorrectionKind
{
    Rename,
    Merge,
    Reassign,
    ProfessorConfirmation,
    Review,
    Split,
}

public sealed record SpeakerCorrectionOperation
{
    public Guid Id { get; init; }
    public SpeakerCorrectionKind Kind { get; init; }
    public string? SpeakerID { get; init; }
    public string? TargetSpeakerID { get; init; }
    public string? DisplayName { get; init; }
    public IReadOnlyList<Guid> SegmentIDs { get; init; } = [];
    public DateTimeOffset CreatedAt { get; init; }
    public double? AnchorStart { get; init; }
    public double? AnchorEnd { get; init; }
    public string? AnchorText { get; init; }
    public int? SplitAfterWordIndex { get; init; }
    public bool? IsActive { get; init; }
}

public sealed record HumanCorrectionOverlay
{
    public int SchemaVersion { get; init; } = 1;
    public IReadOnlyList<SpeakerCorrectionOperation> Operations { get; init; } = [];
    public string? EditedAllText { get; init; }
    public string? EditedProfessorText { get; init; }
}

/// Explicit provenance for text that a person deliberately saved. Automatic
/// transcript projections use a separate SessionStore API and cannot populate
/// this type accidentally through nullable text parameters.
public sealed record HumanCorrectionUpdate
{
    public IReadOnlyList<SpeakerCorrectionOperation> Operations { get; init; } = [];
    public string? AllText { get; init; }
    public string? ProfessorText { get; init; }
    public bool ClearAllText { get; init; }
    public bool ClearProfessorText { get; init; }
}

public sealed record HumanCorrectionOverlayReference
{
    public int SchemaVersion { get; init; } = 1;
    public string RelativePath { get; init; } = string.Empty;
}

internal sealed class CaptureScopeJsonConverter : JsonConverter<CaptureScope>
{
    public override CaptureScope Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        CaptureScopeText.TryParse(reader.GetString() ?? string.Empty, out var scope)
            ? scope
            : throw new JsonException("Alcance de captura desconocido.");

    public override void Write(Utf8JsonWriter writer, CaptureScope value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToToken());
}

internal sealed class CapturePhaseJsonConverter : JsonConverter<CapturePhase>
{
    public override CapturePhase Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        CapturePhaseText.TryParse(reader.GetString() ?? string.Empty, out var phase)
            ? phase
            : throw new JsonException("Fase de captura desconocida.");

    public override void Write(Utf8JsonWriter writer, CapturePhase value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToToken());
}

internal sealed class AsrPhaseJsonConverter : JsonConverter<AsrPhase>
{
    public override AsrPhase Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        AsrPhaseText.TryParse(reader.GetString() ?? string.Empty, out var phase)
            ? phase
            : throw new JsonException("Fase ASR desconocida.");

    public override void Write(Utf8JsonWriter writer, AsrPhase value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToToken());
}

internal sealed class SessionPhaseJsonConverter : JsonConverter<SessionPhase>
{
    public override SessionPhase Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        SessionPhaseText.TryParse(reader.GetString() ?? string.Empty, out var phase)
            ? phase
            : throw new JsonException("Fase de sesión desconocida.");

    public override void Write(Utf8JsonWriter writer, SessionPhase value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToToken());
}

internal sealed class SpeakerCorrectionKindJsonConverter : JsonConverter<SpeakerCorrectionKind>
{
    public override SpeakerCorrectionKind Read(
        ref Utf8JsonReader reader,
        Type typeToConvert,
        JsonSerializerOptions options)
    {
        if (reader.TokenType == JsonTokenType.String)
        {
            return reader.GetString()?.Trim() switch
            {
                "rename" => SpeakerCorrectionKind.Rename,
                "merge" => SpeakerCorrectionKind.Merge,
                "reassign" => SpeakerCorrectionKind.Reassign,
                "professorConfirmation" => SpeakerCorrectionKind.ProfessorConfirmation,
                "review" => SpeakerCorrectionKind.Review,
                "split" => SpeakerCorrectionKind.Split,
                _ => throw new JsonException("Tipo de corrección de hablante desconocido."),
            };
        }

        // Accept the initial numeric representation so an interrupted future
        // migration can still be opened, but never emit it again.
        if (reader.TokenType == JsonTokenType.Number
            && reader.TryGetInt32(out var numeric)
            && Enum.IsDefined(typeof(SpeakerCorrectionKind), numeric))
        {
            return (SpeakerCorrectionKind)numeric;
        }

        throw new JsonException("Tipo de corrección de hablante inválido.");
    }

    public override void Write(
        Utf8JsonWriter writer,
        SpeakerCorrectionKind value,
        JsonSerializerOptions options) =>
        writer.WriteStringValue(value switch
        {
            SpeakerCorrectionKind.Rename => "rename",
            SpeakerCorrectionKind.Merge => "merge",
            SpeakerCorrectionKind.Reassign => "reassign",
            SpeakerCorrectionKind.ProfessorConfirmation => "professorConfirmation",
            SpeakerCorrectionKind.Review => "review",
            SpeakerCorrectionKind.Split => "split",
            _ => throw new ArgumentOutOfRangeException(nameof(value)),
        });
}

internal sealed class ClassMetadataJsonConverter : JsonConverter<ClassMetadata>
{
    public override ClassMetadata Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var document = JsonDocument.ParseValue(ref reader);
        var root = document.RootElement;
        var schemaVersion = ReadOptionalInt(root, "schemaVersion") ?? 1;
        if (schemaVersion is < 1 or > 2)
        {
            throw new JsonException($"La versión de metadata {schemaVersion} no es compatible.");
        }

        var stateText = ReadOptionalString(root, "state");
        var state = stateText is null
            ? ProcessingState.Ready
            : ProcessingStateText.Parse(stateText);
        var scopeText = ReadOptionalString(root, "captureScope");
        var modeText = ReadOptionalString(root, "mode");
        CaptureScope scope;
        CaptureMode mode;
        if (scopeText is not null)
        {
            if (!CaptureScopeText.TryParse(scopeText, out scope))
            {
                throw new JsonException($"Alcance de captura desconocido: {scopeText}");
            }

            mode = modeText is null
                ? scope == CaptureScope.Microphone ? CaptureMode.InPerson : CaptureMode.Online
                : CaptureModeText.Parse(modeText);
        }
        else if (modeText is not null)
        {
            mode = CaptureModeText.Parse(modeText);
            scope = mode.ToScope();
        }
        else
        {
            mode = CaptureMode.InPerson;
            scope = CaptureScope.Microphone;
        }

        var sessionPhaseText = ReadOptionalString(root, "sessionPhase");
        SessionPhase sessionPhase;
        if (sessionPhaseText is null)
        {
            sessionPhase = state.ToSessionPhase();
        }
        else if (SessionPhaseText.TryParse(sessionPhaseText, out var parsedSessionPhase))
        {
            sessionPhase = parsedSessionPhase;
        }
        else
        {
            throw new JsonException($"Fase de sesión desconocida: {sessionPhaseText}");
        }

        var capturePhaseText = ReadOptionalString(root, "capturePhase");
        CapturePhase capturePhase;
        if (capturePhaseText is null)
        {
            capturePhase = state.ToCapturePhase();
        }
        else if (CapturePhaseText.TryParse(capturePhaseText, out var parsedCapturePhase))
        {
            capturePhase = parsedCapturePhase;
        }
        else
        {
            throw new JsonException($"Fase de captura desconocida: {capturePhaseText}");
        }

        var asrPhaseText = ReadOptionalString(root, "asrPhase");
        AsrPhase asrPhase;
        if (asrPhaseText is null)
        {
            asrPhase = state.ToAsrPhase();
        }
        else if (AsrPhaseText.TryParse(asrPhaseText, out var parsedAsrPhase))
        {
            asrPhase = parsedAsrPhase;
        }
        else
        {
            throw new JsonException($"Fase ASR desconocida: {asrPhaseText}");
        }

        var languageText = ReadOptionalString(root, "transcriptionLanguage")
            ?? ReadOptionalString(root, "language");
        var language = languageText is null ? "es" : ParseLanguage(languageText);

        return new ClassMetadata
        {
            SchemaVersion = schemaVersion,
            Id = GetGuid(root, "id") ?? Guid.NewGuid(),
            Subject = GetString(root, "subject") ?? string.Empty,
            StartedAt = GetDateTimeOffset(root, "startedAt") ?? DateTimeOffset.Now,
            Duration = GetDouble(root, "duration") ?? 0,
            Mode = mode,
            CaptureScope = scope,
            Source = GetString(root, "source") ?? string.Empty,
            ProfessorSpeakerID = GetString(root, "professorSpeakerID"),
            ProfessorSelectionIsAutomatic = GetBool(root, "professorSelectionIsAutomatic") ?? true,
            SpeakerCount = GetInt(root, "speakerCount") ?? 0,
            State = state,
            SessionPhase = sessionPhase,
            CapturePhase = capturePhase,
            AsrPhase = asrPhase,
            FolderPath = GetString(root, "folderPath") ?? string.Empty,
            TechnicalVocabulary = GetString(root, "technicalVocabulary") ?? string.Empty,
            Language = language,
            AudioFormat = GetString(root, "audioFormat") ?? PcmWaveFile.AudioFormatName,
            FormatVersion = GetInt(root, "formatVersion") ?? 1,
            Platform = GetString(root, "platform") ?? "windows",
            AttemptID = Deserialize<SessionAttemptID>(root, "sessionAttemptID", options),
            AsrOriginalReference = Deserialize<ASRTranscriptReference>(root, "asrOriginalReference", options),
            AudioManifestReference = Deserialize<AudioManifestReference>(root, "audioManifestReference", options),
            DiarizationProposalReferences = Deserialize<List<DiarizationProposalReference>>(root, "diarizationProposals", options) ?? [],
            HumanCorrectionOverlayReference = Deserialize<HumanCorrectionOverlayReference>(root, "humanCorrectionOverlay", options),
        };
    }

    public override void Write(Utf8JsonWriter writer, ClassMetadata value, JsonSerializerOptions options)
    {
        var scope = value.CaptureScope ?? value.Mode.ToScope();
        writer.WriteStartObject();
        writer.WriteNumber("schemaVersion", 2);
        writer.WriteString("id", value.Id);
        writer.WriteString("subject", value.Subject);
        writer.WriteString("startedAt", value.StartedAt);
        writer.WriteNumber("duration", value.Duration);
        writer.WriteString("mode", value.Mode.ToPersistentToken());
        writer.WriteString("captureScope", scope.ToToken());
        writer.WriteString("source", value.Source);
        WriteNullableString(writer, "professorSpeakerID", value.ProfessorSpeakerID);
        writer.WriteBoolean("professorSelectionIsAutomatic", value.ProfessorSelectionIsAutomatic);
        writer.WriteNumber("speakerCount", value.SpeakerCount);
        writer.WriteString("state", value.State.ToToken());
        writer.WriteString("sessionPhase", (value.SessionPhase ?? value.State.ToSessionPhase()).ToToken());
        writer.WriteString("capturePhase", (value.CapturePhase ?? value.State.ToCapturePhase()).ToToken());
        writer.WriteString("asrPhase", (value.AsrPhase ?? value.State.ToAsrPhase()).ToToken());
        writer.WriteString("folderPath", value.FolderPath);
        writer.WriteString("technicalVocabulary", value.TechnicalVocabulary);
        writer.WriteString("transcriptionLanguage", NormalizeLanguage(value.Language));
        writer.WriteString("language", NormalizeLanguage(value.Language));
        writer.WriteString("audioFormat", value.AudioFormat);
        writer.WriteNumber("formatVersion", value.FormatVersion);
        writer.WriteString("platform", value.Platform);
        WriteNullableObject(writer, "sessionAttemptID", value.AttemptID, options);
        WriteNullableObject(writer, "asrOriginalReference", value.AsrOriginalReference, options);
        WriteNullableObject(writer, "audioManifestReference", value.AudioManifestReference, options);
        writer.WritePropertyName("diarizationProposals");
        JsonSerializer.Serialize(writer, value.DiarizationProposalReferences, options);
        WriteNullableObject(writer, "humanCorrectionOverlay", value.HumanCorrectionOverlayReference, options);
        writer.WriteEndObject();
    }

    private static T? Deserialize<T>(JsonElement root, string name, JsonSerializerOptions options)
    {
        return root.TryGetProperty(name, out var value)
            ? JsonSerializer.Deserialize<T>(value.GetRawText(), options)
            : default;
    }

    private static string? GetString(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static string? ReadOptionalString(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out var value))
        {
            return null;
        }

        if (value.ValueKind != JsonValueKind.String)
        {
            throw new JsonException($"El campo {name} debe ser texto cuando está presente.");
        }

        return value.GetString();
    }

    private static int? ReadOptionalInt(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out var value))
        {
            return null;
        }

        if (!value.TryGetInt32(out var parsed))
        {
            throw new JsonException($"El campo {name} debe ser un entero cuando está presente.");
        }

        return parsed;
    }

    private static Guid? GetGuid(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value)
            && value.ValueKind == JsonValueKind.String
            && Guid.TryParse(value.GetString(), out var parsed)
            ? parsed
            : null;

    private static DateTimeOffset? GetDateTimeOffset(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.String)
        {
            return null;
        }

        return DateTimeOffset.TryParse(value.GetString(), out var parsed) ? parsed : null;
    }

    private static int? GetInt(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value) && value.TryGetInt32(out var parsed) ? parsed : null;

    private static double? GetDouble(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value) && value.TryGetDouble(out var parsed) ? parsed : null;

    private static bool? GetBool(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value) && (value.ValueKind == JsonValueKind.True || value.ValueKind == JsonValueKind.False)
            ? value.GetBoolean()
            : null;

    private static string NormalizeLanguage(string? language) => language?.Trim().ToLowerInvariant() switch
    {
        "en" => "en",
        "fr" => "fr",
        _ => "es",
    };

    private static string ParseLanguage(string language) => language.Trim().ToLowerInvariant() switch
    {
        "es" => "es",
        "en" => "en",
        "fr" => "fr",
        _ => throw new JsonException($"Idioma de transcripción desconocido: {language}"),
    };

    private static void WriteNullableString(Utf8JsonWriter writer, string name, string? value)
    {
        if (value is null)
        {
            writer.WriteNull(name);
        }
        else
        {
            writer.WriteString(name, value);
        }
    }

    private static void WriteNullableObject<T>(Utf8JsonWriter writer, string name, T? value, JsonSerializerOptions options)
        where T : class
    {
        writer.WritePropertyName(name);
        if (value is null)
        {
            writer.WriteNullValue();
        }
        else
        {
            JsonSerializer.Serialize(writer, value, options);
        }
    }
}
