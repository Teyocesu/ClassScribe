using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.Resources;
using System.Runtime.CompilerServices;
using ClassScribe.Core;

namespace ClassScribe.Windows;

internal enum InterfaceLanguage
{
    System,
    Spanish,
    English,
    French,
}

internal static class InterfaceLanguageCodes
{
    public const string System = "system";
    public const string Spanish = "es";
    public const string English = "en";
    public const string French = "fr";

    public static string Normalize(string? code) => code?.Trim().ToLowerInvariant() switch
    {
        System => System,
        Spanish => Spanish,
        French => French,
        _ => English,
    };

    public static string Resolve(string? selection, string? systemCulture)
    {
        var normalized = Normalize(selection);
        if (normalized != System)
        {
            return normalized;
        }

        var language = (systemCulture ?? string.Empty)
            .Replace('_', '-')
            .Split('-', 2, StringSplitOptions.RemoveEmptyEntries)
            .FirstOrDefault()
            ?.ToLowerInvariant();
        return language switch
        {
            Spanish => Spanish,
            French => French,
            _ => English,
        };
    }
}

internal interface IInterfaceLanguagePreferenceStore
{
    string? Load();

    void Save(string code);
}

internal sealed class FileInterfaceLanguagePreferenceStore : IInterfaceLanguagePreferenceStore
{
    private readonly string path;

    public FileInterfaceLanguagePreferenceStore(string? path = null)
    {
        this.path = path
            ?? Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "ClassScribe",
                "interfaceLocale.txt");
    }

    public string? Load()
    {
        try
        {
            return File.Exists(path) ? File.ReadAllText(path).Trim() : null;
        }
        catch (IOException)
        {
            return null;
        }
        catch (UnauthorizedAccessException)
        {
            return null;
        }
    }

    public void Save(string code)
    {
        try
        {
            var directory = Path.GetDirectoryName(path);
            if (!string.IsNullOrWhiteSpace(directory))
            {
                Directory.CreateDirectory(directory);
            }

            File.WriteAllText(path, code + Environment.NewLine);
        }
        catch (IOException)
        {
            // A preference write must never interrupt recording or processing.
        }
        catch (UnauthorizedAccessException)
        {
            // A preference write must never interrupt recording or processing.
        }
    }
}

internal sealed class InMemoryInterfaceLanguagePreferenceStore : IInterfaceLanguagePreferenceStore
{
    public string? Value { get; private set; }

    public string? Load() => Value;

    public void Save(string code) => Value = code;
}

internal sealed class LocalizedMessage
{
    private LocalizedMessage(string? key, string? rawValue, object?[] arguments)
    {
        Key = key;
        RawValue = rawValue;
        Arguments = arguments;
    }

    public string? Key { get; }

    public string? RawValue { get; }

    public object?[] Arguments { get; }

    public static LocalizedMessage Keyed(string key, params object?[] arguments) =>
        new(key, null, arguments);

    public static LocalizedMessage Raw(string value) => new(null, value, []);
}

internal sealed class InterfaceLanguageOption : ObservableObject
{
    private string name;

    public InterfaceLanguageOption(string code, string name)
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
        Name = localization.InterfaceLanguageName(Code);
}

public sealed class AppLocalization : INotifyPropertyChanged
{
    private static readonly ResourceManager Resources = new(
        "ClassScribe.Windows.Localization.AppStrings",
        typeof(AppLocalization).Assembly);

    private readonly IInterfaceLanguagePreferenceStore preferenceStore;
    private readonly Func<string> systemCultureProvider;
    private readonly bool applyThreadCulture;
    private string selectionCode;

    public static AppLocalization Instance { get; } = new();

    internal AppLocalization(
        IInterfaceLanguagePreferenceStore? preferenceStore = null,
        Func<string>? systemCultureProvider = null,
        bool applyThreadCulture = true)
    {
        this.preferenceStore = preferenceStore ?? new FileInterfaceLanguagePreferenceStore();
        var initialSystemCulture = CultureInfo.CurrentUICulture.Name;
        this.systemCultureProvider = systemCultureProvider ?? (() => initialSystemCulture);
        this.applyThreadCulture = applyThreadCulture;
        var saved = this.preferenceStore.Load();
        selectionCode = saved is null
            ? InterfaceLanguageCodes.Spanish
            : InterfaceLanguageCodes.Normalize(saved);
        ApplyCulture();
        foreach (var option in InterfaceLanguages)
        {
            option.Refresh(this);
        }
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public string InterfaceLanguageCode
    {
        get => selectionCode;
        set => Select(value);
    }

    public string ResolvedLanguageCode =>
        InterfaceLanguageCodes.Resolve(selectionCode, systemCultureProvider());

    public CultureInfo Culture => CultureInfo.GetCultureInfo(ResolvedLanguageCode);

    internal ObservableCollection<InterfaceLanguageOption> InterfaceLanguages { get; } =
    [
        new(InterfaceLanguageCodes.System, string.Empty),
        new(InterfaceLanguageCodes.Spanish, string.Empty),
        new(InterfaceLanguageCodes.English, string.Empty),
        new(InterfaceLanguageCodes.French, string.Empty),
    ];

    public TranscriptMetadataLabels MetadataLabels => new(
        this["ExportSubject"],
        this["ExportDate"],
        this["ExportDuration"],
        this["ExportMode"],
        this["ExportSource"],
        this["ExportTranscript"],
        this["ExportOnlineMode"],
        this["ExportInPersonMode"]);

    public string this[string key] => Get(key);

    public string Get(string key, params object?[] arguments)
    {
        var template = Resources.GetString(key, Culture)
            ?? Resources.GetString(key, CultureInfo.GetCultureInfo(InterfaceLanguageCodes.English))
            ?? $"[{key}]";
        if (arguments.Length == 0)
        {
            return template;
        }

        try
        {
            return string.Format(Culture, template, arguments);
        }
        catch (FormatException)
        {
            return template;
        }
    }

    internal string Resolve(LocalizedMessage message)
    {
        if (message.RawValue is not null)
        {
            return message.RawValue;
        }

        return message.Key is null ? string.Empty : Get(message.Key, message.Arguments);
    }

    public string InterfaceLanguageName(string code) => InterfaceLanguageCodes.Normalize(code) switch
    {
        InterfaceLanguageCodes.System => Get("LanguageSystem"),
        InterfaceLanguageCodes.Spanish => Get("LanguageSpanish"),
        InterfaceLanguageCodes.French => Get("LanguageFrench"),
        _ => Get("LanguageEnglish"),
    };

    public void Select(string code)
    {
        var normalized = InterfaceLanguageCodes.Normalize(code);
        if (selectionCode == normalized)
        {
            return;
        }

        selectionCode = normalized;
        preferenceStore.Save(selectionCode);
        ApplyCulture();
        OnPropertyChanged(nameof(InterfaceLanguageCode));
        OnPropertyChanged(nameof(ResolvedLanguageCode));
        OnPropertyChanged(nameof(Culture));
        OnPropertyChanged(nameof(MetadataLabels));
        OnPropertyChanged("Item[]");
        OnPropertyChanged(string.Empty);
        foreach (var option in InterfaceLanguages)
        {
            option.Refresh(this);
        }
    }

    public bool HasResource(string key, string languageCode)
    {
        var resolved = InterfaceLanguageCodes.Resolve(languageCode, systemCultureProvider());
        var culture = CultureInfo.GetCultureInfo(resolved);
        return Resources.GetString(key, culture) is { Length: > 0 };
    }

    private void ApplyCulture()
    {
        if (!applyThreadCulture)
        {
            return;
        }

        try
        {
            CultureInfo.CurrentUICulture = Culture;
            CultureInfo.CurrentCulture = Culture;
        }
        catch (CultureNotFoundException)
        {
            CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo(InterfaceLanguageCodes.English);
            CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo(InterfaceLanguageCodes.English);
        }
    }

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
}

internal static class SpeakerPresentation
{
    public static string LocalizedName(
        string id,
        string? storedDisplayName,
        AppLocalization localization)
    {
        var candidate = id.Trim();
        var stored = storedDisplayName?.Trim();
        var storedIsAutomatic = stored is null || string.Equals(stored, candidate, StringComparison.Ordinal);
        if (IsUnknown(candidate) || (storedDisplayName is not null && IsUnknown(storedDisplayName)))
        {
            return localization["SpeakerUnknown"];
        }

        // Human-entered display names are presentation data and must win over
        // the legacy, Spanish-shaped ID. Only the automatic value that still
        // mirrors the ID is eligible for localization.
        if (!string.IsNullOrWhiteSpace(stored) && !storedIsAutomatic)
        {
            return stored;
        }

        if (TryPersonNumber(candidate, out var number)
            || (storedDisplayName is not null && TryPersonNumber(storedDisplayName, out number)))
        {
            return localization.Get("SpeakerPerson", number);
        }

        if (IsProfessor(candidate) || (storedDisplayName is not null && IsProfessor(storedDisplayName)))
        {
            return localization["SpeakerProfessor"];
        }

        if (IsParticipant(candidate) || (storedDisplayName is not null && IsParticipant(storedDisplayName)))
        {
            return localization["SpeakerParticipant"];
        }

        return stored ?? id;
    }

    private static bool IsUnknown(string value) => value.Trim().ToLowerInvariant() is
        "persona desconocida" or "unknown person" or "personne inconnue" or "unknown speaker";

    private static bool IsProfessor(string value) => value.Trim().ToLowerInvariant() is
        "profesor" or "professor" or "professeur";

    private static bool IsParticipant(string value) => value.Trim().ToLowerInvariant() is
        "participante" or "participant";

    private static bool TryPersonNumber(string value, out int number)
    {
        var parts = value.Trim().Split([' ', '_', '-'], StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 2
            && int.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out number)
            && parts[0].ToLowerInvariant() is "persona" or "person" or "personne" or "speaker")
        {
            return true;
        }

        number = 0;
        return false;
    }
}

internal static class ReviewReasonPresentation
{
    public static string Localized(string reason, AppLocalization localization)
    {
        var normalized = reason.Trim().ToLowerInvariant();
        if (normalized.StartsWith("voces superpuestas", StringComparison.Ordinal)
            || normalized.StartsWith("overlapping voices", StringComparison.Ordinal)
            || normalized.StartsWith("voix superposées", StringComparison.Ordinal))
        {
            return localization["ReviewOverlapping"];
        }

        var open = reason.LastIndexOf('(');
        if (open >= 0 && reason.EndsWith(')'))
        {
            var score = reason[(open + 1)..^1];
            return localization.Get("ReviewLowConfidence", score);
        }

        return reason;
    }
}
