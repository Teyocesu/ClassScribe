import Foundation
import Testing
@testable import ClassScribe

@Test("System resolves supported interface languages and falls back to English")
func systemInterfaceLanguageResolution() {
    #expect(InterfaceLanguageResolver.resolve(.system, preferredLanguages: ["es-AR"]) == .spanish)
    #expect(InterfaceLanguageResolver.resolve(.system, preferredLanguages: ["fr_FR"]) == .french)
    #expect(InterfaceLanguageResolver.resolve(.system, preferredLanguages: ["en-US"]) == .english)
    #expect(InterfaceLanguageResolver.resolve(.system, preferredLanguages: ["de-DE"]) == .english)
    #expect(InterfaceLanguageResolver.resolve(.system, preferredLanguages: []) == .english)
}

@Test("Interface language preference round-trips independently of sessions")
func interfaceLanguagePreferenceRoundTrip() {
    let suiteName = "ClassScribe.LocalizationTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = InterfaceLanguagePreferenceStore(defaults: defaults)
    #expect(store.load() == .spanish)
    store.save(.french)
    #expect(store.load() == .french)
}

@Test("Changing interface language never changes transcription language")
@MainActor
func interfaceLanguageDoesNotChangeTranscriptionLanguage() {
    let suiteName = "ClassScribe.LocalizationTests.Model.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let model = ClassScribeModel(
        store: SessionStore(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("ClassScribe.LocalizationTests.\(UUID().uuidString)")
        ),
        capture: CaptureController(),
        interfaceLanguageStore: InterfaceLanguagePreferenceStore(defaults: defaults),
        preferredLanguages: { ["en-US"] },
    )
    model.language = .french
    model.interfaceLanguage = .english

    #expect(model.language == .french)
    #expect(model.resolvedInterfaceLanguage == .english)
}

@Test("Main localization keys exist in Spanish, English, and French")
func mainLocalizationKeysAreComplete() {
    let keys: [LocalizationKey] = [
        .appLanguageLabel,
        .headerSubtitle,
        .configTitle,
        .subjectLabel,
        .captureModeOnline,
        .captureModeInPerson,
        .transcriptionLanguageLabel,
        .buttonStartRecording,
        .buttonStopRecording,
        .buttonPauseText,
        .buttonResumeText,
        .buttonCancel,
        .consentTitle,
        .historyTitle,
        .transcriptLiveTitle,
        .transcriptEveryoneTitle,
        .reviewTitle,
        .copyForChatGPT,
        .exportAction,
        .errorStorage,
    ]

    for language in ResolvedInterfaceLanguage.allCases {
        for key in keys {
            #expect(ClassScribeLocalization.hasTranslation(key, language: language))
        }
    }
}

@Test("Speaker presentation translates labels without changing durable IDs")
func speakerPresentationPreservesIDs() {
    let speakerID = "Persona 1"
    #expect(
        SpeakerPresentation.localizedName(
            id: speakerID,
            storedDisplayName: speakerID,
            language: .english,
        ) == "Person 1"
    )
    #expect(
        SpeakerPresentation.localizedName(
            id: "Persona desconocida",
            storedDisplayName: "Persona desconocida",
            language: .french,
        ) == "Personne inconnue"
    )
    #expect(speakerID == "Persona 1")
}

@Test("Export metadata follows interface language while transcript stays exact")
func localizedExportMetadataPreservesTranscript() {
    let transcript = "Persona 1: El número π permanece igual."
    let english = TranscriptActions.chatEnvelope(
        subject: "Física",
        date: Date(timeIntervalSince1970: 0),
        duration: 12,
        mode: .online,
        source: "Zoom",
        transcript: transcript,
        interfaceLanguage: .english,
    )
    #expect(english.contains("Subject:"))
    #expect(english.contains("Date:"))
    #expect(english.contains("Duration:"))
    #expect(english.contains("Mode:"))
    #expect(english.contains("Source:"))
    #expect(english.contains("Transcript:"))
    #expect(english.contains(transcript))
    #expect(!english.contains("Materia:"))

    let french = TranscriptActions.chatEnvelope(
        subject: "Física",
        date: Date(timeIntervalSince1970: 0),
        duration: 12,
        mode: .inPerson,
        source: "Microphone",
        transcript: transcript,
        interfaceLanguage: .french,
    )
    #expect(french.contains("Matière:"))
    #expect(french.contains("Durée:"))
    #expect(french.contains("Transcription:"))
    #expect(french.contains(transcript))
}

@Test("Missing localization keys use a visible safe fallback")
func missingLocalizationKeyFallsBackSafely() {
    #expect(
        ClassScribeLocalization.text("missing.localization.key", language: .english)
            == "[missing.localization.key]"
    )
}
