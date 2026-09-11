using ClassScribe.Core;
using ClassScribe.Windows;

namespace ClassScribe.Windows.Tests;

[TestClass]
public sealed class LocalizationTests
{
    [TestMethod]
    public void SystemResolvesSupportedLanguagesAndFallsBackToEnglish()
    {
        Assert.AreEqual("es", InterfaceLanguageCodes.Resolve("system", "es-AR"));
        Assert.AreEqual("fr", InterfaceLanguageCodes.Resolve("system", "fr_FR"));
        Assert.AreEqual("en", InterfaceLanguageCodes.Resolve("system", "en-US"));
        Assert.AreEqual("en", InterfaceLanguageCodes.Resolve("system", "de-DE"));
        Assert.AreEqual("en", InterfaceLanguageCodes.Resolve("system", string.Empty));
    }

    [TestMethod]
    public void SelectionPersistsAndChangesImmediately()
    {
        var store = new InMemoryInterfaceLanguagePreferenceStore();
        var localization = NewLocalization(store, "de-DE");

        Assert.AreEqual("es", localization.InterfaceLanguageCode);
        Assert.AreEqual("Idioma de la aplicación", localization["AppLanguageLabel"]);

        localization.Select("en");

        Assert.AreEqual("en", localization.InterfaceLanguageCode);
        Assert.AreEqual("en", store.Value);
        Assert.AreEqual("App language", localization["AppLanguageLabel"]);

        var reopened = NewLocalization(store, "de-DE");
        Assert.AreEqual("en", reopened.InterfaceLanguageCode);
        Assert.AreEqual("App language", reopened["AppLanguageLabel"]);
    }

    [TestMethod]
    public void MainKeysExistInSpanishEnglishAndFrench()
    {
        var keys = new[]
        {
            "AppLanguageLabel",
            "HeaderSubtitle",
            "SubjectLabel",
            "CaptureModeOnline",
            "CaptureModeInPerson",
            "TranscriptionLanguageLabel",
            "StartRecording",
            "StopProcessing",
            "PauseText",
            "ResumeText",
            "CancelProcess",
            "ConsentTitle",
            "TabLive",
            "TabAll",
            "TabProfessor",
            "TabReview",
            "HistoryRecoverable",
            "CopyForChat",
            "Export",
            "WarningSourceRead",
        };
        var localization = NewLocalization(new InMemoryInterfaceLanguagePreferenceStore(), "en-US");

        foreach (var language in new[] { "es", "en", "fr" })
        {
            foreach (var key in keys)
            {
                Assert.IsTrue(localization.HasResource(key, language), $"Missing {key} in {language}");
            }
        }
    }

    [TestMethod]
    public void SpeakerPresentationTranslatesWithoutChangingDurableID()
    {
        var localization = Select(
            NewLocalization(new InMemoryInterfaceLanguagePreferenceStore(), "en-US"),
            "en");

        const string speakerID = "Persona 1";
        Assert.AreEqual(
            "Person 1",
            SpeakerPresentation.LocalizedName(speakerID, speakerID, localization));
        Assert.AreEqual(
            "Personne inconnue",
            SpeakerPresentation.LocalizedName(
                "Persona desconocida",
                "Persona desconocida",
                Select(localization, "fr")));
    }

    [TestMethod]
    public void MissingResourceFallsBackToEnglishTemplate()
    {
        var localization = NewLocalization(new InMemoryInterfaceLanguagePreferenceStore(), "en-US");

        Assert.AreEqual("[Missing.Key]", localization["Missing.Key"]);
        Assert.IsFalse(localization.HasResource("Missing.Key", "fr"));
    }

    private static AppLocalization NewLocalization(
        IInterfaceLanguagePreferenceStore store,
        string systemCulture) =>
        new(store, () => systemCulture, applyThreadCulture: false);

    private static AppLocalization Select(AppLocalization localization, string code)
    {
        localization.Select(code);
        return localization;
    }
}
