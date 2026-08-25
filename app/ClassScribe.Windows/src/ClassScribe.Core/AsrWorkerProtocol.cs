using System.Text.Json;
using System.Text.Json.Serialization;

namespace ClassScribe.Core;

public static class AsrWorkerProtocol
{
    public const int SupportedVersion = 1;
    public const int MaximumMessageBytes = 1_048_576;
}

[JsonConverter(typeof(AsrMessageTypeJsonConverter))]
public enum AsrMessageType
{
    Hello,
    Ready,
    Heartbeat,
    Progress,
    Start,
    Result,
    RecoverableError,
    TerminalError,
    Cancel,
    Cancelled,
    Shutdown,
}

public sealed class AsrWorkerProtocolException : Exception
{
    public AsrWorkerProtocolException(string message) : base(message) { }
}

public sealed record AsrWorkerEnvelope
{
    [JsonPropertyName("protocolVersion")]
    public int ProtocolVersion { get; init; } = AsrWorkerProtocol.SupportedVersion;
    [JsonPropertyName("attemptID")]
    public SessionAttemptID AttemptID { get; init; } = new();
    [JsonPropertyName("jobID")]
    public Guid JobID { get; init; }
    [JsonPropertyName("messageType")]
    public AsrMessageType MessageType { get; init; }
    [JsonPropertyName("supportedVersions")]
    public IReadOnlyList<int>? SupportedVersions { get; init; }
    [JsonPropertyName("selectedVersion")]
    public int? SelectedVersion { get; init; }
    [JsonPropertyName("sourceReference")]
    public string? SourceReference { get; init; }
    [JsonPropertyName("progress")]
    public double? Progress { get; init; }
    [JsonPropertyName("text")]
    public string? Text { get; init; }
    [JsonPropertyName("code")]
    public string? Code { get; init; }
    [JsonPropertyName("message")]
    public string? Message { get; init; }

    public static AsrWorkerEnvelope Hello(SessionAttemptID attemptID, Guid jobID) => new()
    {
        AttemptID = attemptID,
        JobID = jobID,
        MessageType = AsrMessageType.Hello,
        SupportedVersions = [AsrWorkerProtocol.SupportedVersion],
    };

    public static AsrWorkerEnvelope Ready(
        SessionAttemptID attemptID,
        Guid jobID,
        int protocolVersion = AsrWorkerProtocol.SupportedVersion,
        int selectedVersion = AsrWorkerProtocol.SupportedVersion) => new()
    {
        ProtocolVersion = protocolVersion,
        AttemptID = attemptID,
        JobID = jobID,
        MessageType = AsrMessageType.Ready,
        SelectedVersion = selectedVersion,
    };

    public static AsrWorkerEnvelope Heartbeat(SessionAttemptID attemptID, Guid jobID) => new()
    {
        AttemptID = attemptID,
        JobID = jobID,
        MessageType = AsrMessageType.Heartbeat,
    };

    public static AsrWorkerEnvelope ProgressMessage(
        SessionAttemptID attemptID,
        Guid jobID,
        double progress) => new()
    {
        AttemptID = attemptID,
        JobID = jobID,
        MessageType = AsrMessageType.Progress,
        Progress = progress,
    };

    public static AsrWorkerEnvelope StartMessage(
        SessionAttemptID attemptID,
        Guid jobID,
        string? sourceReference = null) => new()
    {
        AttemptID = attemptID,
        JobID = jobID,
        MessageType = AsrMessageType.Start,
        SourceReference = sourceReference,
    };

    public static AsrWorkerEnvelope Result(
        SessionAttemptID attemptID,
        Guid jobID,
        string? text) => new()
    {
        AttemptID = attemptID,
        JobID = jobID,
        MessageType = AsrMessageType.Result,
        Text = text,
    };

    public static AsrWorkerEnvelope Error(
        SessionAttemptID attemptID,
        Guid jobID,
        bool recoverable,
        string code,
        string message) => new()
    {
        AttemptID = attemptID,
        JobID = jobID,
        MessageType = recoverable ? AsrMessageType.RecoverableError : AsrMessageType.TerminalError,
        Code = code,
        Message = message,
    };

    public byte[] Encode(JsonSerializerOptions? options = null)
    {
        ValidateShape();
        var data = JsonSerializer.SerializeToUtf8Bytes(this, options);
        if (data.Length > AsrWorkerProtocol.MaximumMessageBytes)
        {
            throw new AsrWorkerProtocolException("El mensaje ASR excede el límite de tamaño.");
        }

        return data;
    }

    public static AsrWorkerEnvelope Decode(
        ReadOnlySpan<byte> data,
        JsonSerializerOptions? options = null)
    {
        if (data.Length > AsrWorkerProtocol.MaximumMessageBytes)
        {
            throw new AsrWorkerProtocolException("El mensaje ASR excede el límite de tamaño.");
        }

        var message = JsonSerializer.Deserialize<AsrWorkerEnvelope>(data, options)
            ?? throw new AsrWorkerProtocolException("El mensaje ASR está vacío.");
        message.ValidateShape();
        return message;
    }

    public void ValidateShape()
    {
        if (ProtocolVersion <= 0)
        {
            throw new AsrWorkerProtocolException("La versión del protocolo ASR debe ser positiva.");
        }

        if (AttemptID.SessionID == Guid.Empty
            || AttemptID.Generation <= 0
            || AttemptID.Nonce == Guid.Empty
            || JobID == Guid.Empty)
        {
            throw new AsrWorkerProtocolException("El mensaje ASR no tiene identidad válida.");
        }

        switch (MessageType)
        {
            case AsrMessageType.Hello when SupportedVersions is null
                || SupportedVersions.Count == 0
                || SupportedVersions.Any(version => version <= 0):
                throw new AsrWorkerProtocolException("hello sin versiones soportadas.");
            case AsrMessageType.Ready when SelectedVersion is null || SelectedVersion <= 0:
                throw new AsrWorkerProtocolException("ready sin versión seleccionada.");
            case AsrMessageType.Progress when Progress is null
                || !double.IsFinite(Progress.Value)
                || Progress.Value < 0
                || Progress.Value > 1:
                throw new AsrWorkerProtocolException("progreso fuera de rango.");
            case AsrMessageType.Result when Text is null:
                throw new AsrWorkerProtocolException("result sin texto.");
            case AsrMessageType.RecoverableError or AsrMessageType.TerminalError
                when string.IsNullOrWhiteSpace(Code) || string.IsNullOrWhiteSpace(Message):
                throw new AsrWorkerProtocolException("error sin código o mensaje.");
        }
    }
}

public enum AsrWorkerExitKind
{
    Clean,
    Crashed,
}

public sealed record AsrWorkerExit(AsrWorkerExitKind Kind, int Status);

public enum AsrWorkerTransportFaultKind
{
    LaunchFailed,
    MalformedFrame,
    OversizedFrame,
    UnexpectedEof,
    ReadFailed,
    WriteFailed,
}

public sealed record AsrWorkerTransportFault(
    AsrWorkerTransportFaultKind Kind,
    string? Message = null);

public interface IAsrWorkerTransport
{
    event Action<AsrWorkerEnvelope>? MessageReceived;
    event Action<AsrWorkerExit>? Exited;
    event Action<AsrWorkerTransportFault>? Faulted;
    bool IsTerminated { get; }

    // Implementations must enqueue writes and return without waiting for IPC.
    // Terminate must be able to kill the process independently of that queue.
    void Start(AsrWorkerEnvelope hello);
    void Send(AsrWorkerEnvelope message);
    void Terminate();
}

internal sealed class AsrMessageTypeJsonConverter : JsonConverter<AsrMessageType>
{
    public override AsrMessageType Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.String)
        {
            throw new JsonException("messageType debe ser un token string.");
        }

        var value = reader.GetString();
        return value switch
        {
            "hello" => AsrMessageType.Hello,
            "ready" => AsrMessageType.Ready,
            "heartbeat" => AsrMessageType.Heartbeat,
            "progress" => AsrMessageType.Progress,
            "start" => AsrMessageType.Start,
            "result" => AsrMessageType.Result,
            "recoverableError" => AsrMessageType.RecoverableError,
            "terminalError" => AsrMessageType.TerminalError,
            "cancel" => AsrMessageType.Cancel,
            "cancelled" => AsrMessageType.Cancelled,
            "shutdown" => AsrMessageType.Shutdown,
            _ => throw new JsonException($"messageType desconocido: {value}"),
        };
    }

    public override void Write(Utf8JsonWriter writer, AsrMessageType value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value switch
        {
            AsrMessageType.Hello => "hello",
            AsrMessageType.Ready => "ready",
            AsrMessageType.Heartbeat => "heartbeat",
            AsrMessageType.Progress => "progress",
            AsrMessageType.Start => "start",
            AsrMessageType.Result => "result",
            AsrMessageType.RecoverableError => "recoverableError",
            AsrMessageType.TerminalError => "terminalError",
            AsrMessageType.Cancel => "cancel",
            AsrMessageType.Cancelled => "cancelled",
            AsrMessageType.Shutdown => "shutdown",
            _ => throw new ArgumentOutOfRangeException(nameof(value)),
        });
}
