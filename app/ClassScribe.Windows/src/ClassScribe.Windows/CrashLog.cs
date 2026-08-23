using System.Text;

namespace ClassScribe.Windows;

internal static class CrashLog
{
    private const long MaximumLogBytes = 4 * 1_024 * 1_024;
    private const int MaximumEntryCharacters = 64 * 1_024;

    public static void Write(Exception exception)
    {
        try
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

            var path = Path.Combine(directory, $"crash-{DateTimeOffset.Now:yyyyMMdd}.log");
            var entry = $"[{DateTimeOffset.Now:O}]\n{exception}\n\n";
            if (entry.Length > MaximumEntryCharacters)
            {
                entry = entry[..MaximumEntryCharacters] + "\n[entrada truncada]\n\n";
            }

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
            using var writer = new StreamWriter(
                stream,
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
            writer.Write(entry);
        }
        catch (Exception logException) when (logException is IOException or UnauthorizedAccessException)
        {
            // Logging must never hide the original failure.
        }
    }
}
