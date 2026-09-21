using System.Diagnostics;
using System.Text;
using ClassScribe.Core;

namespace ClassScribe.Windows;

/// Opt-in, local-only timing marks for finalization and startup investigations.
/// The normal application path does not perform any work here. Entries contain
/// only fixed stage names, monotonic timestamps, and session-attempt identity.
internal static class ProcessingDiagnostics
{
    private const string EnableVariable = "CLASSSCRIBE_PERF_DIAGNOSTICS";
    private const long MaximumLogBytes = 512 * 1_024;
    private const int MaximumEntryCharacters = 4 * 1_024;
    private static readonly bool enabled =
        string.Equals(Environment.GetEnvironmentVariable(EnableVariable), "1", StringComparison.Ordinal);
    private static readonly object gate = new();

    public static bool IsEnabled => enabled;

    public static double ElapsedMilliseconds(long startedAt, long endedAt) =>
        Stopwatch.GetElapsedTime(startedAt, endedAt).TotalMilliseconds;

    public static long Mark(
        string eventName,
        SessionAttemptID? attempt = null,
        long? startedAt = null,
        string? detail = null)
    {
        var timestamp = Stopwatch.GetTimestamp();
        if (!enabled)
        {
            return timestamp;
        }

        try
        {
            var entry = new StringBuilder()
                .Append(DateTimeOffset.UtcNow.ToString("O"))
                .Append(" mono_ms=")
                .Append(timestamp * 1_000d / Stopwatch.Frequency)
                .Append(" event=")
                .Append(Sanitize(eventName))
                .Append(" attempt=")
                .Append(attempt?.Token ?? "none");
            if (startedAt is long start)
            {
                entry.Append(" elapsed_ms=")
                    .Append(Stopwatch.GetElapsedTime(start).TotalMilliseconds);
            }

            if (!string.IsNullOrWhiteSpace(detail))
            {
                entry.Append(" detail=").Append(Sanitize(detail));
            }

            var line = entry.ToString();
            _ = Task.Run(() =>
            {
                try
                {
                    Write(line);
                }
                catch (Exception)
                {
                    // Diagnostics must never affect capture or processing.
                }
            });
        }
        catch (Exception)
        {
            // Diagnostics must never affect capture or processing.
        }

        return timestamp;
    }

    private static void Write(string message)
    {
        var directory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "ClassScribe",
            "Logs");
        Directory.CreateDirectory(directory);
        if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0)
        {
            return;
        }

        var path = Path.Combine(directory, $"processing-timing-{DateTimeOffset.UtcNow:yyyyMMdd}.log");
        var entry = message.Length > MaximumEntryCharacters
            ? message[..MaximumEntryCharacters] + " [truncated]"
            : message;
        entry += Environment.NewLine;

        lock (gate)
        {
            var mode = FileMode.Append;
            if (File.Exists(path))
            {
                if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                {
                    return;
                }

                if (new FileInfo(path).Length >= MaximumLogBytes)
                {
                    mode = FileMode.Create;
                }
            }

            using var stream = new FileStream(path, mode, FileAccess.Write, FileShare.Read);
            using var writer = new StreamWriter(stream, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
            writer.Write(entry);
        }
    }

    private static string Sanitize(string value) =>
        value.Replace('\r', ' ').Replace('\n', ' ').Replace(' ', '_');
}
