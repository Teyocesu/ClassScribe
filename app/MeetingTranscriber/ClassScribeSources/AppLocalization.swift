import Foundation

/// Language selected for ClassScribe's interface. This setting is deliberately
/// separate from `TranscriptionLanguage`, which belongs to a class session.
enum InterfaceLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case spanish = "es"
    case english = "en"
    case french = "fr"

    var id: String { rawValue }
}

enum ResolvedInterfaceLanguage: String, CaseIterable, Sendable {
    case spanish = "es"
    case english = "en"
    case french = "fr"

    var localeIdentifier: String { rawValue }
}

enum InterfaceLanguageResolver {
    static func resolve(
        _ selection: InterfaceLanguage,
        preferredLanguages: [String],
    ) -> ResolvedInterfaceLanguage {
        switch selection {
        case .spanish: return .spanish
        case .english: return .english
        case .french: return .french
        case .system:
            let preferred = preferredLanguages.first?
                .replacingOccurrences(of: "_", with: "-")
                .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map(String.init) ?? ""
            switch preferred.lowercased() {
            case "es": return .spanish
            case "fr": return .french
            default: return .english
            }
        }
    }
}

struct InterfaceLanguagePreferenceStore {
    static let key = "interfaceLocale"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(default fallback: InterfaceLanguage = .spanish) -> InterfaceLanguage {
        guard let raw = defaults.string(forKey: Self.key),
              let value = InterfaceLanguage(rawValue: raw)
        else { return fallback }
        return value
    }

    func save(_ language: InterfaceLanguage) {
        defaults.set(language.rawValue, forKey: Self.key)
    }
}

enum LocalizationKey: String, CaseIterable, Sendable {
    case appLanguageLabel
    case languageSystem
    case languageSpanish
    case languageEnglish
    case languageFrench
    case headerSubtitle
    case headerLocalProcessing
    case configTitle
    case subjectLabel
    case subjectPlaceholder
    case classTypeLabel
    case captureModeOnline
    case captureModeInPerson
    case transcriptionLanguageLabel
    case supportedLanguages
    case onlineSourceLabel
    case audioSourceOnlineAccessibility
    case onlineSourceApplication
    case onlineSourceSystemOutput
    case applicationPickerLabel
    case microphonePickerLabel
    case selectApplication
    case selectMicrophone
    case systemOutputHint
    case refreshAudioSources
    case technicalVocabularyHelp
    case technicalVocabularyPlaceholder
    case technicalVocabularyLabel
    case buttonStartRecording
    case buttonStopRecording
    case buttonPauseText
    case buttonResumeText
    case buttonCancel
    case buttonCancelProcessing
    case buttonFinish
    case buttonRetryProcessing
    case statusSaving
    case statusPreparingTranscription
    case statusConnectingAudio
    case statusReady
    case statusStartingAudioCallback
    case statusStartingApplicationCapture
    case statusStartingSystemCapture
    case statusRecordingSaved
    case statusSelectSystemOutputScope
    case statusSystemOutputCancelled
    case statusSystemOutputSelected
    case statusPreparingBeforeRecording
    case statusRecordingAndTranscribing
    case statusRecordingPaused
    case statusRecordingContinuesTextPaused
    case statusTranscriptionResumed
    case statusAudioValidationFailed
    case statusCheckpointSaving
    case statusClosingAudio
    case statusStartCancelledCleanup
    case statusStartCancelledBeforeSession
    case statusStartCancelledCleanupFinished
    case statusCancellingProcessing
    case statusProcessingCancelled
    case statusProfessorChanged
    case statusProfessorCalibrating
    case statusVoiceReferenceSaved
    case statusHistoryRecoverable
    case statusHistoryLoaded
    case statusRetryAudioValidation
    case statusRetryAudioRecovered
    case statusRetryAudioReady
    case statusAwaitingCallbacks
    case statusNoCallbacks
    case statusSilentCapture
    case statusAudibleCapture
    case statusClosingAfterCaptureError
    case statusCaptureRecoverable
    case statusCaptureDiagnosticAudio
    case statusWaitingForSpeech
    case statusRecentAudioRecovered
    case statusRecoveredTextAvailable
    case statusPreparingVoiceAndTranscription
    case statusPreparingLocalTranscription
    case statusTextUpdated
    case statusTextCanBeEdited
    case statusLiveUnavailable
    case statusLiveRetry
    case statusFullTranscriptSaved
    case statusLiveVisibleWhilePreparing
    case statusSpeakerIdentification
    case statusFinalReplacedLive
    case statusFinalReadyWithEdits
    case statusFinalOutputsIncomplete
    case statusFinalCancelled
    case statusFinalTranscriptionFailed
    case statusDiarizationFailed
    case statusProfessorVoiceMatch
    case statusExportSaved
    case statusRecoveryStateSaved
    case statusFailed
    case statusComplete
    case statusRecoverable
    case errorSelectSource
    case errorStartTranscription
    case errorSystemOutputAuthorization
    case errorMicrophonePermission
    case errorMicrophoneUnavailable
    case errorApplicationNotRunning
    case errorApplicationIdentityAmbiguous
    case errorApplicationIdentityUnsupported
    case errorApplicationAudioUnavailable
    case errorApplicationAudioStopped
    case errorCaptureCallbacksStalled
    case errorLiveTranscription
    case errorEmptyAudio
    case errorWavHeaderOnly
    case errorEmptyAudioFile
    case errorInvalidAudioFile
    case errorInvalidRawAudio
    case errorNotRecording
    case errorAudioFinalization
    case errorCheckpoint
    case errorCopyEmpty
    case errorCalibration
    case errorReadableTextMissing
    case errorEditSave
    case errorReprocess
    case errorReprocessUnavailable
    case errorFinalProcessingAlreadyRunning
    case errorExportSave
    case errorRecoverySave
    case errorLiveUpdateSave
    case errorMetadata
    case errorDiarization
    case errorModelUnavailable
    case errorEmptyTranscript
    case errorExportEmpty
    case errorExportMissingTimedSegments
    case warningTechnicalVocabulary
    case errorStorage
    case warningSRTTitle
    case warningSRTBody
    case warningSRTExport
    case warningSRTCancel
    case consentTitle
    case consentBody
    case consentConfirm
    case consentCancel
    case guidanceSubject
    case guidanceApplication
    case guidanceMicrophone
    case audioLevel
    case voicesTitle
    case voicesEmpty
    case voicesDescription
    case calibrationInProgress
    case calibrationButton
    case calibrationHelp
    case professorLabel
    case professorAutomatic
    case historyTitle
    case historyEmpty
    case historyRecoverable
    case professorChoose
    case professorConfirm
    case professorConfirmed
    case transcriptPickerLabel
    case transcriptTitle
    case transcriptLiveTitle
    case transcriptEveryoneTitle
    case reviewTitle
    case transcriptEmptyTitle
    case transcriptEmptyDescription
    case livePlaceholder
    case liveFollowing
    case liveNewText
    case liveNewTextAction
    case liveEditing
    case liveAccessibilityHelp
    case livePaused
    case liveFollowAction
    case liveCorrectionsKept
    case liveFinalReplaced
    case professorUnavailable
    case copyTranscript
    case copyForChatGPT
    case openTextFile
    case showFolder
    case exportAction
    case actions
    case hide
    case reviewEmptyTitle
    case reviewEmptyDescription
    case reviewAssign
    case reviewAssigned
    case reviewDescription
    case speakerUnknown
    case speakerPerson
    case speakerProfessor
    case speakerParticipant
    case modeOnlineMetadata
    case modeInPersonMetadata
    case exportSubject
    case exportDate
    case exportDuration
    case exportMode
    case exportSource
    case exportTranscript
    case exportProvisionalDuration
    case exportKindTXT
    case exportKindMarkdown
    case exportKindSRT
}

struct LocalizedMessage: Equatable, Sendable {
    let key: LocalizationKey?
    let rawValue: String?
    let arguments: [String: String]

    static func key(
        _ key: LocalizationKey,
        arguments: [String: String] = [:],
    ) -> Self {
        Self(key: key, rawValue: nil, arguments: arguments)
    }

    static func raw(_ value: String) -> Self {
        Self(key: nil, rawValue: value, arguments: [:])
    }
}

enum ClassScribeLocalization {
    static func text(
        _ key: LocalizationKey,
        language: ResolvedInterfaceLanguage,
        arguments: [String: String] = [:],
    ) -> String {
        text(key.rawValue, language: language, arguments: arguments)
    }

    static func text(
        _ key: String,
        language: ResolvedInterfaceLanguage,
        arguments: [String: String] = [:],
    ) -> String {
        let template = translations[key]?[language]
            ?? translations[key]?[.english]
            ?? "[\(key)]"
        return arguments.reduce(template) { result, pair in
            result.replacingOccurrences(of: "{{\(pair.key)}}", with: pair.value)
        }
    }

    static func resolve(
        _ message: LocalizedMessage,
        language: ResolvedInterfaceLanguage,
    ) -> String {
        if let rawValue = message.rawValue { return rawValue }
        guard let key = message.key else { return "" }
        return text(key, language: language, arguments: message.arguments)
    }

    static func hasTranslation(
        _ key: LocalizationKey,
        language: ResolvedInterfaceLanguage,
    ) -> Bool {
        guard let value = translations[key.rawValue]?[language] else { return false }
        return !value.isEmpty
    }

    private static let translations: [String: [ResolvedInterfaceLanguage: String]] = [
        LocalizationKey.appLanguageLabel.rawValue: [.spanish: "Idioma de la aplicación", .english: "App language", .french: "Langue de l’application"],
        LocalizationKey.languageSystem.rawValue: [.spanish: "Sistema", .english: "System", .french: "Système"],
        LocalizationKey.languageSpanish.rawValue: [.spanish: "Español", .english: "Spanish", .french: "Espagnol"],
        LocalizationKey.languageEnglish.rawValue: [.spanish: "Inglés", .english: "English", .french: "Anglais"],
        LocalizationKey.languageFrench.rawValue: [.spanish: "Francés", .english: "French", .french: "Français"],
        LocalizationKey.headerSubtitle.rawValue: [.spanish: "Graba y transcribe tus clases en esta Mac", .english: "Record and transcribe your classes on this Mac", .french: "Enregistrez et transcrivez vos cours sur ce Mac"],
        LocalizationKey.headerLocalProcessing.rawValue: [.spanish: "Procesamiento local", .english: "Local processing", .french: "Traitement local"],
        LocalizationKey.configTitle.rawValue: [.spanish: "Configura la clase", .english: "Set up the class", .french: "Configurer le cours"],
        LocalizationKey.subjectLabel.rawValue: [.spanish: "Materia", .english: "Subject", .french: "Matière"],
        LocalizationKey.subjectPlaceholder.rawValue: [.spanish: "Ej.: Análisis matemático", .english: "E.g. Mathematical analysis", .french: "Ex. : Analyse mathématique"],
        LocalizationKey.classTypeLabel.rawValue: [.spanish: "Tipo de clase", .english: "Class type", .french: "Type de cours"],
        LocalizationKey.captureModeOnline.rawValue: [.spanish: "Clase online", .english: "Online class", .french: "Cours en ligne"],
        LocalizationKey.captureModeInPerson.rawValue: [.spanish: "Clase presencial", .english: "In-person class", .french: "Cours en présentiel"],
        LocalizationKey.transcriptionLanguageLabel.rawValue: [.spanish: "Idioma de transcripción", .english: "Transcription language", .french: "Langue de transcription"],
        LocalizationKey.supportedLanguages.rawValue: [.spanish: "Reconocimiento optimizado para español, inglés o francés.", .english: "Recognition is optimized for Spanish, English, or French.", .french: "La reconnaissance est optimisée pour l’espagnol, l’anglais ou le français."],
        LocalizationKey.onlineSourceLabel.rawValue: [.spanish: "Fuente online", .english: "Online source", .french: "Source en ligne"],
        LocalizationKey.audioSourceOnlineAccessibility.rawValue: [.spanish: "Fuente de audio online", .english: "Online audio source", .french: "Source audio en ligne"],
        LocalizationKey.onlineSourceApplication.rawValue: [.spanish: "Una aplicación", .english: "An application", .french: "Une application"],
        LocalizationKey.onlineSourceSystemOutput.rawValue: [.spanish: "Audio del equipo", .english: "Computer audio", .french: "Audio de l’ordinateur"],
        LocalizationKey.applicationPickerLabel.rawValue: [.spanish: "Aplicación", .english: "Application", .french: "Application"],
        LocalizationKey.microphonePickerLabel.rawValue: [.spanish: "Micrófono", .english: "Microphone", .french: "Microphone"],
        LocalizationKey.selectApplication.rawValue: [.spanish: "Seleccionar aplicación…", .english: "Select application…", .french: "Sélectionner une application…"],
        LocalizationKey.selectMicrophone.rawValue: [.spanish: "Seleccionar micrófono…", .english: "Select microphone…", .french: "Sélectionner un microphone…"],
        LocalizationKey.systemOutputHint.rawValue: [.spanish: "Captura todo el audio que sale por tu equipo.", .english: "Capture all audio played by your computer.", .french: "Capturez tout l’audio lu par votre ordinateur."],
        LocalizationKey.refreshAudioSources.rawValue: [.spanish: "Actualizar fuentes de audio", .english: "Refresh audio sources", .french: "Actualiser les sources audio"],
        LocalizationKey.technicalVocabularyHelp.rawValue: [.spanish: "Ayuda a reconocer nombres, siglas y términos propios de la materia.", .english: "Helps recognize names, acronyms, and terms specific to the subject.", .french: "Aide à reconnaître les noms, acronymes et termes propres à la matière."],
        LocalizationKey.technicalVocabularyPlaceholder.rawValue: [.spanish: "Ej.: Newton-Raphson, Runge-Kutta, PMBOK", .english: "E.g. Newton-Raphson, Runge-Kutta, PMBOK", .french: "Ex. : Newton-Raphson, Runge-Kutta, PMBOK"],
        LocalizationKey.technicalVocabularyLabel.rawValue: [.spanish: "Agregar vocabulario técnico (opcional)", .english: "Add technical vocabulary (optional)", .french: "Ajouter du vocabulaire technique (facultatif)"],
        LocalizationKey.buttonStartRecording.rawValue: [.spanish: "Iniciar grabación", .english: "Start recording", .french: "Démarrer l’enregistrement"],
        LocalizationKey.buttonStopRecording.rawValue: [.spanish: "Detener", .english: "Stop", .french: "Arrêter"],
        LocalizationKey.buttonPauseText.rawValue: [.spanish: "Pausar texto", .english: "Pause text", .french: "Mettre le texte en pause"],
        LocalizationKey.buttonResumeText.rawValue: [.spanish: "Reanudar", .english: "Resume", .french: "Reprendre"],
        LocalizationKey.buttonCancel.rawValue: [.spanish: "Cancelar", .english: "Cancel", .french: "Annuler"],
        LocalizationKey.buttonCancelProcessing.rawValue: [.spanish: "Cancelar procesamiento", .english: "Cancel processing", .french: "Annuler le traitement"],
        LocalizationKey.buttonFinish.rawValue: [.spanish: "Finalizar", .english: "Finish", .french: "Terminer"],
        LocalizationKey.buttonRetryProcessing.rawValue: [.spanish: "Reintentar procesamiento", .english: "Retry processing", .french: "Réessayer le traitement"],
        LocalizationKey.statusSaving.rawValue: [.spanish: "Guardando…", .english: "Saving…", .french: "Enregistrement…"],
        LocalizationKey.statusPreparingTranscription.rawValue: [.spanish: "Preparando transcripción…", .english: "Preparing transcription…", .french: "Préparation de la transcription…"],
        LocalizationKey.statusConnectingAudio.rawValue: [.spanish: "Conectando al audio…", .english: "Connecting to audio…", .french: "Connexion à l’audio…"],
        LocalizationKey.statusReady.rawValue: [.spanish: "Selecciona una fuente y escribe el nombre de la materia.", .english: "Select a source and enter the subject name.", .french: "Sélectionnez une source et saisissez le nom de la matière."],
        LocalizationKey.statusStartingAudioCallback.rawValue: [.spanish: "Esperando el primer callback de audio antes de iniciar el contador.", .english: "Waiting for the first audio callback before starting the timer.", .french: "En attente du premier callback audio avant de lancer le chronomètre."],
        LocalizationKey.statusStartingApplicationCapture.rawValue: [.spanish: "Iniciando la captura de audio de la aplicación seleccionada.", .english: "Starting audio capture from the selected application.", .french: "Démarrage de la capture audio de l’application sélectionnée."],
        LocalizationKey.statusStartingSystemCapture.rawValue: [.spanish: "Iniciando la captura de todo el audio que sale por tu equipo.", .english: "Starting capture of all audio played by your computer.", .french: "Démarrage de la capture de tout l’audio lu par votre ordinateur."],
        LocalizationKey.statusRecordingSaved.rawValue: [.spanish: "El audio se guarda aunque pauses la transcripción.", .english: "Audio is saved even when transcription is paused.", .french: "L’audio est enregistré même lorsque la transcription est en pause."],
        LocalizationKey.statusSelectSystemOutputScope.rawValue: [.spanish: "Confirma el alcance de captura para iniciar el audio del equipo.", .english: "Confirm the capture scope to start recording computer audio.", .french: "Confirmez la portée de la capture pour enregistrer l’audio de l’ordinateur."],
        LocalizationKey.statusSystemOutputCancelled.rawValue: [.spanish: "Captura del audio del equipo cancelada.", .english: "Computer audio capture cancelled.", .french: "Capture de l’audio de l’ordinateur annulée."],
        LocalizationKey.statusSystemOutputSelected.rawValue: [.spanish: "Audio del equipo seleccionado. Presiona Iniciar grabación para continuar.", .english: "Computer audio selected. Select Start recording to continue.", .french: "Audio de l’ordinateur sélectionné. Sélectionnez Démarrer l’enregistrement pour continuer."],
        LocalizationKey.statusPreparingBeforeRecording.rawValue: [.spanish: "Preparando transcripción antes de grabar…", .english: "Preparing transcription before recording…", .french: "Préparation de la transcription avant l’enregistrement…"],
        LocalizationKey.statusRecordingAndTranscribing.rawValue: [.spanish: "Grabando y transcribiendo", .english: "Recording and transcribing", .french: "Enregistrement et transcription"],
        LocalizationKey.statusRecordingPaused.rawValue: [.spanish: "Grabando · texto pausado", .english: "Recording · text paused", .french: "Enregistrement · texte en pause"],
        LocalizationKey.statusRecordingContinuesTextPaused.rawValue: [.spanish: "Grabando audio · transcripción en vivo pausada", .english: "Recording audio · live transcription paused", .french: "Enregistrement audio · transcription en direct en pause"],
        LocalizationKey.statusTranscriptionResumed.rawValue: [.spanish: "Transcripción reanudada; el audio siguió grabándose.", .english: "Transcription resumed; audio continued recording.", .french: "Transcription reprise ; l’audio a continué d’être enregistré."],
        LocalizationKey.statusAudioValidationFailed.rawValue: [.spanish: "El audio se conservó, pero no se pudo validar: {{error}}", .english: "Audio was preserved, but it could not be validated: {{error}}", .french: "L’audio a été conservé, mais n’a pas pu être validé : {{error}}"],
        LocalizationKey.statusCheckpointSaving.rawValue: [.spanish: "Guardando transcripción antes de cerrar el audio.", .english: "Saving the transcript before closing the audio.", .french: "Enregistrement de la transcription avant de fermer l’audio."],
        LocalizationKey.statusClosingAudio.rawValue: [.spanish: "Cerrando y validando el audio.", .english: "Closing and validating audio.", .french: "Fermeture et validation de l’audio."],
        LocalizationKey.statusStartCancelledCleanup.rawValue: [.spanish: "Inicio cancelado; se espera la limpieza nativa antes del próximo intento.", .english: "Start cancelled; waiting for native cleanup before the next attempt.", .french: "Démarrage annulé ; nettoyage natif en attente avant le prochain essai."],
        LocalizationKey.statusStartCancelledBeforeSession.rawValue: [.spanish: "Inicio cancelado antes de crear la sesión.", .english: "Start cancelled before the session was created.", .french: "Démarrage annulé avant la création de la session."],
        LocalizationKey.statusStartCancelledCleanupFinished.rawValue: [.spanish: "Inicio cancelado; la limpieza nativa terminó.", .english: "Start cancelled; native cleanup finished.", .french: "Démarrage annulé ; le nettoyage natif est terminé."],
        LocalizationKey.statusCancellingProcessing.rawValue: [.spanish: "Cancelando procesamiento; el texto y el audio permanecen disponibles.", .english: "Cancelling processing; the text and audio remain available.", .french: "Annulation du traitement ; le texte et l’audio restent disponibles."],
        LocalizationKey.statusProcessingCancelled.rawValue: [.spanish: "Procesamiento cancelado; se conservaron el audio y el mejor texto disponible.", .english: "Processing cancelled; audio and the best available text were preserved.", .french: "Traitement annulé ; l’audio et le meilleur texte disponible ont été conservés."],
        LocalizationKey.statusProfessorChanged.rawValue: [.spanish: "Profesor cambiado a {{id}}; vista filtrada regenerada.", .english: "Professor changed to {{id}}; filtered view regenerated.", .french: "Professeur changé pour {{id}} ; vue filtrée régénérée."],
        LocalizationKey.statusProfessorCalibrating.rawValue: [.spanish: "Calibración: procura que hable principalmente el profesor durante 20 segundos.", .english: "Calibration: have mostly the professor speak for 20 seconds.", .french: "Calibration : faites parler principalement le professeur pendant 20 secondes."],
        LocalizationKey.statusVoiceReferenceSaved.rawValue: [.spanish: "Referencia local de voz calibrada. No se subió ningún dato.", .english: "Local voice reference calibrated. No data was uploaded.", .french: "Référence vocale locale calibrée. Aucune donnée n’a été envoyée."],
        LocalizationKey.statusHistoryRecoverable.rawValue: [.spanish: "Sesión recuperable cargada. El audio y el mejor texto disponible permanecen intactos.", .english: "Recoverable session loaded. Audio and the best available text remain intact.", .french: "Session récupérable chargée. L’audio et le meilleur texte disponible restent intacts."],
        LocalizationKey.statusHistoryLoaded.rawValue: [.spanish: "Sesión del historial cargada.", .english: "History session loaded.", .french: "Session de l’historique chargée."],
        LocalizationKey.statusRetryAudioValidation.rawValue: [.spanish: "Validando el audio conservado antes de reintentar.", .english: "Validating preserved audio before retrying.", .french: "Validation de l’audio conservé avant une nouvelle tentative."],
        LocalizationKey.statusRetryAudioRecovered.rawValue: [.spanish: "Audio recuperado; reintentando el procesamiento.", .english: "Audio recovered; retrying processing.", .french: "Audio récupéré ; nouvelle tentative de traitement."],
        LocalizationKey.statusRetryAudioReady.rawValue: [.spanish: "Audio listo; reintentando el procesamiento.", .english: "Audio ready; retrying processing.", .french: "Audio prêt ; nouvelle tentative de traitement."],
        LocalizationKey.statusAwaitingCallbacks.rawValue: [.spanish: "Esperando callbacks de audio; la captura aún está conectando.", .english: "Waiting for audio callbacks; capture is still connecting.", .french: "En attente des callbacks audio ; la capture se connecte encore."],
        LocalizationKey.statusNoCallbacks.rawValue: [.spanish: "La fuente dejó de entregar callbacks; el audio recibido se conserva.", .english: "The source stopped delivering callbacks; received audio is preserved.", .french: "La source ne fournit plus de callbacks ; l’audio reçu est conservé."],
        LocalizationKey.statusSilentCapture.rawValue: [.spanish: "Captura activa con callbacks silenciosos; el silencio no es un fallo.", .english: "Capture is active with silent callbacks; silence is not a failure.", .french: "Capture active avec callbacks silencieux ; le silence n’est pas une erreur."],
        LocalizationKey.statusAudibleCapture.rawValue: [.spanish: "Audio recibido; esperando voz o un resultado de transcripción.", .english: "Audio received; waiting for speech or a transcription result.", .french: "Audio reçu ; en attente de voix ou d’un résultat de transcription."],
        LocalizationKey.statusClosingAfterCaptureError.rawValue: [.spanish: "Cerrando y validando el audio después del error de la fuente.", .english: "Closing and validating audio after the source error.", .french: "Fermeture et validation de l’audio après l’erreur de la source."],
        LocalizationKey.statusCaptureRecoverable.rawValue: [.spanish: "La captura se detuvo, pero el audio se conservó y puede reprocesarse.", .english: "Capture stopped, but audio was preserved and can be reprocessed.", .french: "La capture s’est arrêtée, mais l’audio a été conservé et peut être retraité."],
        LocalizationKey.statusCaptureDiagnosticAudio.rawValue: [.spanish: "La captura se detuvo y el audio quedó conservado para diagnóstico.", .english: "Capture stopped and audio was preserved for diagnosis.", .french: "La capture s’est arrêtée et l’audio a été conservé pour diagnostic."],
        LocalizationKey.statusWaitingForSpeech.rawValue: [.spanish: "La grabación continúa; esperando voz para actualizar la transcripción.", .english: "Recording continues; waiting for speech to update the transcript.", .french: "L’enregistrement continue ; en attente de voix pour mettre à jour la transcription."],
        LocalizationKey.statusRecentAudioRecovered.rawValue: [.spanish: "La vista en vivo retomó el audio reciente; la versión final recuperará el tramo anterior.", .english: "The live view resumed recent audio; the final version will recover the earlier section.", .french: "La vue en direct a repris l’audio récent ; la version finale récupérera le passage précédent."],
        LocalizationKey.statusRecoveredTextAvailable.rawValue: [.spanish: "El texto recuperado sigue disponible.", .english: "The recovered text remains available.", .french: "Le texte récupéré reste disponible."],
        LocalizationKey.statusPreparingVoiceAndTranscription.rawValue: [.spanish: "Grabando; preparando la detección de voz y la transcripción local…", .english: "Recording; preparing voice detection and local transcription…", .french: "Enregistrement ; préparation de la détection vocale et de la transcription locale…"],
        LocalizationKey.statusPreparingLocalTranscription.rawValue: [.spanish: "Preparando la transcripción local…", .english: "Preparing local transcription…", .french: "Préparation de la transcription locale…"],
        LocalizationKey.statusTextUpdated.rawValue: [.spanish: "Texto actualizado. Puedes corregirlo mientras la grabación continúa.", .english: "Text updated. You can correct it while recording continues.", .french: "Texte mis à jour. Vous pouvez le corriger pendant l’enregistrement."],
        LocalizationKey.statusTextCanBeEdited.rawValue: [.spanish: "Puedes corregir el texto mientras la grabación continúa.", .english: "You can correct the text while recording continues.", .french: "Vous pouvez corriger le texte pendant l’enregistrement."],
        LocalizationKey.statusLiveUnavailable.rawValue: [.spanish: "La grabación continúa sin transcripción en vivo; el audio queda disponible para retranscripción final.", .english: "Recording continues without live transcription; audio remains available for final transcription.", .french: "L’enregistrement continue sans transcription en direct ; l’audio reste disponible pour la transcription finale."],
        LocalizationKey.statusLiveRetry.rawValue: [.spanish: "La grabación continúa; reintento en {{seconds}} s y retranscripción final al detener.", .english: "Recording continues; retrying in {{seconds}} s and performing final transcription on stop.", .french: "L’enregistrement continue ; nouvel essai dans {{seconds}} s et transcription finale à l’arrêt."],
        LocalizationKey.statusFullTranscriptSaved.rawValue: [.spanish: "La transcripción completa ya estaba guardada; se reintenta la identificación de voces.", .english: "The full transcript was already saved; retrying speaker identification.", .french: "La transcription complète était déjà enregistrée ; nouvelle tentative d’identification des voix."],
        LocalizationKey.statusLiveVisibleWhilePreparing.rawValue: [.spanish: "La versión en vivo permanece visible mientras se prepara la versión completa.", .english: "The live version remains visible while the full version is prepared.", .french: "La version en direct reste visible pendant la préparation de la version complète."],
        LocalizationKey.statusSpeakerIdentification.rawValue: [.spanish: "Identificando las voces de la clase…", .english: "Identifying class speakers…", .french: "Identification des voix du cours…"],
        LocalizationKey.statusFinalReplacedLive.rawValue: [.spanish: "La transcripción final reemplazó a la versión provisional.", .english: "The final transcript replaced the provisional version.", .french: "La transcription finale a remplacé la version provisoire."],
        LocalizationKey.statusFinalReadyWithEdits.rawValue: [.spanish: "La versión final está lista y tus correcciones permanecen en Mi edición.", .english: "The final version is ready and your corrections remain in My edits.", .french: "La version finale est prête et vos corrections restent dans Mes modifications."],
        LocalizationKey.statusFinalOutputsIncomplete.rawValue: [.spanish: "El texto sigue disponible, pero no se pudieron confirmar todas las salidas finales.", .english: "The text remains available, but not all final outputs could be confirmed.", .french: "Le texte reste disponible, mais toutes les sorties finales n’ont pas pu être confirmées."],
        LocalizationKey.statusFinalCancelled.rawValue: [.spanish: "Procesamiento cancelado; se conservaron el audio y el texto en vivo.", .english: "Processing cancelled; audio and live text were preserved.", .french: "Traitement annulé ; l’audio et le texte en direct ont été conservés."],
        LocalizationKey.statusFinalTranscriptionFailed.rawValue: [.spanish: "Falló la transcripción final; se conserva el texto en vivo.", .english: "Final transcription failed; live text is preserved.", .french: "La transcription finale a échoué ; le texte en direct est conservé."],
        LocalizationKey.statusDiarizationFailed.rawValue: [.spanish: "La transcripción completa está guardada; falló la identificación de hablantes y puede reintentarse.", .english: "The full transcript is saved; speaker identification failed and can be retried.", .french: "La transcription complète est enregistrée ; l’identification des voix a échoué et peut être réessayée."],
        LocalizationKey.statusProfessorVoiceMatch.rawValue: [.spanish: "Profesor asociado con una referencia local de voz ({{percent}} %).", .english: "Professor matched with a local voice reference ({{percent}}%).", .french: "Professeur associé à une référence vocale locale ({{percent}} %)."],
        LocalizationKey.statusExportSaved.rawValue: [.spanish: "Exportación guardada.", .english: "Export saved.", .french: "Exportation enregistrée."],
        LocalizationKey.statusRecoveryStateSaved.rawValue: [.spanish: "Estado de recuperación guardado.", .english: "Recovery state saved.", .french: "État de récupération enregistré."],
        LocalizationKey.statusFailed.rawValue: [.spanish: "Error", .english: "Error", .french: "Erreur"],
        LocalizationKey.statusComplete.rawValue: [.spanish: "Transcripción final lista", .english: "Final transcript ready", .french: "Transcription finale prête"],
        LocalizationKey.statusRecoverable.rawValue: [.spanish: "Sesión recuperable", .english: "Recoverable session", .french: "Session récupérable"],
        LocalizationKey.errorSelectSource.rawValue: [.spanish: "Selecciona una fuente de audio.", .english: "Select an audio source.", .french: "Sélectionnez une source audio."],
        LocalizationKey.errorStartTranscription.rawValue: [.spanish: "No se pudo preparar la transcripción antes de grabar: {{error}}", .english: "Transcription could not be prepared before recording: {{error}}", .french: "Impossible de préparer la transcription avant l’enregistrement : {{error}}"],
        LocalizationKey.errorStorage.rawValue: [.spanish: "No se pudo guardar la sesión: {{error}}", .english: "The session could not be saved: {{error}}", .french: "Impossible d’enregistrer la session : {{error}}"],
        LocalizationKey.errorSystemOutputAuthorization.rawValue: [.spanish: "La captura del audio del sistema requiere una autorización explícita para este intento.", .english: "System audio capture requires explicit authorization for this attempt.", .french: "La capture de l’audio système nécessite une autorisation explicite pour cet essai."],
        LocalizationKey.errorMicrophonePermission.rawValue: [.spanish: "El permiso de micrófono fue denegado. Actívalo en Privacidad y seguridad.", .english: "Microphone permission was denied. Enable it in Privacy & Security.", .french: "L’autorisation du microphone a été refusée. Activez-la dans Confidentialité et sécurité."],
        LocalizationKey.errorMicrophoneUnavailable.rawValue: [.spanish: "El micrófono seleccionado ya no está disponible. Conéctalo de nuevo o elige otro.", .english: "The selected microphone is no longer available. Reconnect it or choose another.", .french: "Le microphone sélectionné n’est plus disponible. Reconnectez-le ou choisissez-en un autre."],
        LocalizationKey.errorApplicationNotRunning.rawValue: [.spanish: "La aplicación elegida ya no está en ejecución.", .english: "The selected application is no longer running.", .french: "L’application sélectionnée n’est plus en cours d’exécution."],
        LocalizationKey.errorApplicationIdentityAmbiguous.rawValue: [.spanish: "La aplicación seleccionada tiene más de una coincidencia válida. Cierra la copia adicional o vuelve a elegir la fuente.", .english: "The selected application has more than one valid match. Close the extra copy or choose the source again.", .french: "L’application sélectionnée a plusieurs correspondances valides. Fermez la copie supplémentaire ou choisissez à nouveau la source."],
        LocalizationKey.errorApplicationIdentityUnsupported.rawValue: [.spanish: "La aplicación seleccionada no tiene una identidad estable verificable. Vuelve a actualizar y elegir la fuente.", .english: "The selected application has no verifiable stable identity. Refresh and choose the source again.", .french: "L’application sélectionnée n’a pas d’identité stable vérifiable. Actualisez et choisissez à nouveau la source."],
        LocalizationKey.errorApplicationAudioUnavailable.rawValue: [.spanish: "La aplicación no entregó audio. Comprueba que siga abierta y revisa el permiso de Audio del sistema en Privacidad y seguridad.", .english: "The application did not provide audio. Make sure it is open and review the system audio permission in Privacy & Security.", .french: "L’application n’a pas fourni d’audio. Vérifiez qu’elle est ouverte et contrôlez l’autorisation audio système dans Confidentialité et sécurité."],
        LocalizationKey.errorApplicationAudioStopped.rawValue: [.spanish: "La aplicación dejó de entregar audio. Se detuvo la captura para conservar lo grabado; comprueba que la app siga abierta y el permiso de Audio del sistema.", .english: "The application stopped providing audio. Capture stopped to preserve the recording; make sure the app is open and system audio permission is enabled.", .french: "L’application a cessé de fournir de l’audio. La capture s’est arrêtée pour préserver l’enregistrement ; vérifiez que l’application est ouverte et que l’autorisation audio système est active."],
        LocalizationKey.errorCaptureCallbacksStalled.rawValue: [.spanish: "La fuente de audio dejó de entregar callbacks. El audio recibido se conserva para recuperación.", .english: "The audio source stopped delivering callbacks. Received audio is preserved for recovery.", .french: "La source audio ne fournit plus de callbacks. L’audio reçu est conservé pour récupération."],
        LocalizationKey.errorLiveTranscription.rawValue: [.spanish: "Transcripción en vivo no disponible: {{error}}. La grabación continúa.", .english: "Live transcription is unavailable: {{error}}. Recording continues.", .french: "La transcription en direct est indisponible : {{error}}. L’enregistrement continue."],
        LocalizationKey.errorEmptyAudio.rawValue: [.spanish: "El archivo de audio está vacío. El original se conservó para diagnóstico.", .english: "The audio file is empty. The original was preserved for diagnosis.", .french: "Le fichier audio est vide. L’original a été conservé pour diagnostic."],
        LocalizationKey.errorWavHeaderOnly.rawValue: [.spanish: "El micrófono no entregó audio. El archivo se conservó para diagnóstico.", .english: "The microphone provided no audio. The file was preserved for diagnosis.", .french: "Le microphone n’a fourni aucun audio. Le fichier a été conservé pour diagnostic."],
        LocalizationKey.errorEmptyAudioFile.rawValue: [.spanish: "El archivo de audio no llegó a crearse con datos. Se conservó la sesión para diagnóstico.", .english: "The audio file was not created with data. The session was preserved for diagnosis.", .french: "Le fichier audio n’a pas été créé avec des données. La session a été conservée pour diagnostic."],
        LocalizationKey.errorInvalidAudioFile.rawValue: [.spanish: "El audio no es un archivo regular propio de la sesión. No se siguió ni reemplazó ningún enlace.", .english: "The audio is not a regular file belonging to the session. No link was followed or replaced.", .french: "L’audio n’est pas un fichier normal appartenant à la session. Aucun lien n’a été suivi ni remplacé."],
        LocalizationKey.errorInvalidRawAudio.rawValue: [.spanish: "El audio crudo conservado está vacío, truncado o no es un archivo regular.", .english: "The preserved raw audio is empty, truncated, or not a regular file.", .french: "L’audio brut conservé est vide, tronqué ou n’est pas un fichier normal."],
        LocalizationKey.errorNotRecording.rawValue: [.spanish: "No hay una clase en grabación.", .english: "No class is being recorded.", .french: "Aucun cours n’est en cours d’enregistrement."],
        LocalizationKey.errorAudioFinalization.rawValue: [.spanish: "No se pudo finalizar el audio: {{detail}}", .english: "Audio could not be finalized: {{detail}}", .french: "Impossible de finaliser l’audio : {{detail}}"],
        LocalizationKey.errorCheckpoint.rawValue: [.spanish: "No se pudo completar el checkpoint previo: {{error}}", .english: "The previous checkpoint could not be completed: {{error}}", .french: "Impossible de terminer le point de contrôle précédent : {{error}}"],
        LocalizationKey.errorCopyEmpty.rawValue: [.spanish: "Todavía no hay una transcripción para copiar.", .english: "There is no transcript to copy yet.", .french: "Il n’y a pas encore de transcription à copier."],
        LocalizationKey.errorCalibration.rawValue: [.spanish: "No se pudo calibrar la voz: {{error}}", .english: "Voice calibration failed: {{error}}", .french: "Échec de l’étalonnage vocal : {{error}}"],
        LocalizationKey.errorReadableTextMissing.rawValue: [.spanish: "Todavía no existe un TXT legible para esta sesión.", .english: "There is no readable TXT for this session yet.", .french: "Aucun TXT lisible n’existe encore pour cette session."],
        LocalizationKey.errorEditSave.rawValue: [.spanish: "No se pudo guardar la edición: {{error}}", .english: "The edit could not be saved: {{error}}", .french: "Impossible d’enregistrer la modification : {{error}}"],
        LocalizationKey.errorReprocess.rawValue: [.spanish: "No se puede reprocesar el audio: {{error}}", .english: "The audio cannot be reprocessed: {{error}}", .french: "Impossible de retraiter l’audio : {{error}}"],
        LocalizationKey.errorReprocessUnavailable.rawValue: [.spanish: "Esta sesión no conserva audio suficiente para reprocesar.", .english: "This session does not preserve enough audio to reprocess.", .french: "Cette session ne conserve pas assez d’audio pour être retraitée."],
        LocalizationKey.errorFinalProcessingAlreadyRunning.rawValue: [.spanish: "Ya hay un procesamiento final en curso.", .english: "Final processing is already in progress.", .french: "Un traitement final est déjà en cours."],
        LocalizationKey.errorExportSave.rawValue: [.spanish: "No se pudo guardar una exportación: {{error}}", .english: "An export could not be saved: {{error}}", .french: "Impossible d’enregistrer une exportation : {{error}}"],
        LocalizationKey.errorRecoverySave.rawValue: [.spanish: "No se pudo guardar el estado de recuperación: {{error}}", .english: "The recovery state could not be saved: {{error}}", .french: "Impossible d’enregistrer l’état de récupération : {{error}}"],
        LocalizationKey.errorLiveUpdateSave.rawValue: [.spanish: "No se pudo actualizar live-transcript.txt: {{error}}", .english: "live-transcript.txt could not be updated: {{error}}", .french: "Impossible de mettre à jour live-transcript.txt : {{error}}"],
        LocalizationKey.errorMetadata.rawValue: [.spanish: "La metadata no es compatible con esta versión de ClassScribe: {{error}}", .english: "The metadata is not compatible with this version of ClassScribe: {{error}}", .french: "Les métadonnées ne sont pas compatibles avec cette version de ClassScribe : {{error}}"],
        LocalizationKey.errorDiarization.rawValue: [.spanish: "No se pudieron identificar los hablantes. La transcripción completa se conservó y puedes reintentar.", .english: "Speakers could not be identified. The full transcript was preserved and you can retry.", .french: "Les voix n’ont pas pu être identifiées. La transcription complète a été conservée et vous pouvez réessayer."],
        LocalizationKey.errorModelUnavailable.rawValue: [.spanish: "No se pudo preparar la transcripción local. Comprueba la conexión para la primera descarga y el espacio libre.", .english: "Local transcription could not be prepared. Check the connection for the first download and available disk space.", .french: "Impossible de préparer la transcription locale. Vérifiez la connexion pour le premier téléchargement et l’espace disponible."],
        LocalizationKey.errorEmptyTranscript.rawValue: [.spanish: "La transcripción final no produjo texto; se conserva la versión en vivo.", .english: "Final transcription produced no text; the live version is preserved.", .french: "La transcription finale n’a produit aucun texte ; la version en direct est conservée."],
        LocalizationKey.errorExportEmpty.rawValue: [.spanish: "No se puede exportar una transcripción vacía.", .english: "An empty transcript cannot be exported.", .french: "Une transcription vide ne peut pas être exportée."],
        LocalizationKey.errorExportMissingTimedSegments.rawValue: [.spanish: "SRT requiere segmentos con tiempos; el TXT y Markdown siguen disponibles.", .english: "SRT requires timed segments; TXT and Markdown remain available.", .french: "Le SRT nécessite des segments horodatés ; le TXT et le Markdown restent disponibles."],
        LocalizationKey.warningTechnicalVocabulary.rawValue: [.spanish: "No se pudo aplicar el vocabulario técnico; la transcripción base continuó.", .english: "Technical vocabulary could not be applied; the base transcription continued.", .french: "Le vocabulaire technique n’a pas pu être appliqué ; la transcription de base a continué."],
        LocalizationKey.warningSRTTitle.rawValue: [.spanish: "El SRT usa la versión segmentada", .english: "SRT uses the segmented version", .french: "Le SRT utilise la version segmentée"],
        LocalizationKey.warningSRTBody.rawValue: [.spanish: "La edición libre no puede conservar tiempos palabra por palabra. TXT y Markdown sí contienen tu edición.", .english: "Free-form edits cannot preserve word-level timings. TXT and Markdown contain your edits.", .french: "Les modifications libres ne peuvent pas conserver les temps mot à mot. Le TXT et le Markdown contiennent vos modifications."],
        LocalizationKey.warningSRTExport.rawValue: [.spanish: "Exportar SRT segmentado", .english: "Export segmented SRT", .french: "Exporter le SRT segmenté"],
        LocalizationKey.warningSRTCancel.rawValue: [.spanish: "Cancelar", .english: "Cancel", .french: "Annuler"],
        LocalizationKey.consentTitle.rawValue: [.spanish: "Capturar audio del equipo", .english: "Capture computer audio", .french: "Capturer l’audio de l’ordinateur"],
        LocalizationKey.consentBody.rawValue: [.spanish: "ClassScribe capturará todo el audio que salga por el dispositivo de salida del equipo. Esto puede incluir otras aplicaciones, notificaciones y sonidos del sistema.\n\nEl audio se procesa y guarda localmente en tu dispositivo.\n\n¿Quieres continuar?", .english: "ClassScribe will capture all audio played by the computer’s output device. This may include other applications, notifications, and system sounds.\n\nAudio is processed and stored locally on your device.\n\nDo you want to continue?", .french: "ClassScribe capturera tout l’audio lu par le périphérique de sortie de l’ordinateur. Cela peut inclure d’autres applications, des notifications et des sons système.\n\nL’audio est traité et enregistré localement sur votre appareil.\n\nVoulez-vous continuer ?"],
        LocalizationKey.consentConfirm.rawValue: [.spanish: "Capturar audio del equipo", .english: "Capture computer audio", .french: "Capturer l’audio de l’ordinateur"],
        LocalizationKey.consentCancel.rawValue: [.spanish: "Cancelar", .english: "Cancel", .french: "Annuler"],
        LocalizationKey.guidanceSubject.rawValue: [.spanish: "Escribe el nombre de la materia.", .english: "Enter the subject name.", .french: "Saisissez le nom de la matière."],
        LocalizationKey.guidanceApplication.rawValue: [.spanish: "Elige la aplicación donde está la clase.", .english: "Choose the application containing the class.", .french: "Choisissez l’application qui contient le cours."],
        LocalizationKey.guidanceMicrophone.rawValue: [.spanish: "Elige el micrófono que quieres usar.", .english: "Choose the microphone you want to use.", .french: "Choisissez le microphone à utiliser."],
        LocalizationKey.audioLevel.rawValue: [.spanish: "Nivel de audio", .english: "Audio level", .french: "Niveau audio"],
        LocalizationKey.voicesTitle.rawValue: [.spanish: "Voces", .english: "Voices", .french: "Voix"],
        LocalizationKey.voicesEmpty.rawValue: [.spanish: "Aún no hay voces identificadas", .english: "No voices identified yet", .french: "Aucune voix identifiée pour le moment"],
        LocalizationKey.voicesDescription.rawValue: [.spanish: "Se identificarán al finalizar la grabación.", .english: "They will be identified when recording finishes.", .french: "Elles seront identifiées à la fin de l’enregistrement."],
        LocalizationKey.calibrationInProgress.rawValue: [.spanish: "Guardando voz… {{seconds}} s", .english: "Saving voice… {{seconds}} s", .french: "Enregistrement de la voix… {{seconds}} s"],
        LocalizationKey.calibrationButton.rawValue: [.spanish: "Guardar voz del profesor (20 s)", .english: "Save professor voice (20 s)", .french: "Enregistrer la voix du professeur (20 s)"],
        LocalizationKey.calibrationHelp.rawValue: [.spanish: "Crea una referencia local para reconocer al profesor en esta materia.", .english: "Creates a local reference to recognize the professor in this subject.", .french: "Crée une référence locale pour reconnaître le professeur dans cette matière."],
        LocalizationKey.professorLabel.rawValue: [.spanish: "Profesor", .english: "Professor", .french: "Professeur"],
        LocalizationKey.professorAutomatic.rawValue: [.spanish: "Selección automática; puedes cambiarla.", .english: "Automatic selection; you can change it.", .french: "Sélection automatique ; vous pouvez la modifier."],
        LocalizationKey.historyTitle.rawValue: [.spanish: "Clases anteriores", .english: "Previous classes", .french: "Cours précédents"],
        LocalizationKey.historyEmpty.rawValue: [.spanish: "Tus grabaciones aparecerán aquí.", .english: "Your recordings will appear here.", .french: "Vos enregistrements apparaîtront ici."],
        LocalizationKey.historyRecoverable.rawValue: [.spanish: "Necesita recuperar el procesamiento", .english: "Processing recovery required", .french: "Récupération du traitement nécessaire"],
        LocalizationKey.professorChoose.rawValue: [.spanish: "Elegir como profesor", .english: "Choose as professor", .french: "Choisir comme professeur"],
        LocalizationKey.professorConfirm.rawValue: [.spanish: "Confirmar profesor", .english: "Confirm professor", .french: "Confirmer le professeur"],
        LocalizationKey.professorConfirmed.rawValue: [.spanish: "Profesor ✓", .english: "Professor ✓", .french: "Professeur ✓"],
        LocalizationKey.transcriptPickerLabel.rawValue: [.spanish: "Transcripción", .english: "Transcript", .french: "Transcription"],
        LocalizationKey.transcriptTitle.rawValue: [.spanish: "Transcripción", .english: "Transcript", .french: "Transcription"],
        LocalizationKey.transcriptLiveTitle.rawValue: [.spanish: "Transcripción en vivo", .english: "Live transcript", .french: "Transcription en direct"],
        LocalizationKey.transcriptEveryoneTitle.rawValue: [.spanish: "Todos los hablantes", .english: "All speakers", .french: "Tous les locuteurs"],
        LocalizationKey.reviewTitle.rawValue: [.spanish: "Revisar", .english: "Review", .french: "À vérifier"],
        LocalizationKey.transcriptEmptyTitle.rawValue: [.spanish: "La transcripción aparecerá aquí", .english: "The transcript will appear here", .french: "La transcription apparaîtra ici"],
        LocalizationKey.transcriptEmptyDescription.rawValue: [.spanish: "Configura la clase y pulsa Iniciar grabación.", .english: "Set up the class and select Start recording.", .french: "Configurez le cours et sélectionnez Démarrer l’enregistrement."],
        LocalizationKey.livePlaceholder.rawValue: [.spanish: "La transcripción aparecerá aquí mientras habla el profesor…", .english: "The transcript will appear here while the professor speaks…", .french: "La transcription apparaîtra ici pendant que le professeur parle…"],
        LocalizationKey.liveFollowing.rawValue: [.spanish: "Siguiendo la transcripción automáticamente.", .english: "Following the transcript automatically.", .french: "Suivi automatique de la transcription."],
        LocalizationKey.liveNewText.rawValue: [.spanish: "Hay texto nuevo; tu cursor y tu posición no se movieron.", .english: "There is new text; your cursor and position did not move.", .french: "Du nouveau texte est disponible ; votre curseur et votre position n’ont pas bougé."],
        LocalizationKey.liveNewTextAction.rawValue: [.spanish: "Ver texto nuevo", .english: "View new text", .french: "Voir le nouveau texte"],
        LocalizationKey.liveEditing.rawValue: [.spanish: "Edición activa: tu cursor y tu posición quedan fijos.", .english: "Editing is active: your cursor and position stay fixed.", .french: "Modification active : votre curseur et votre position restent fixes."],
        LocalizationKey.liveAccessibilityHelp.rawValue: [.spanish: "El seguimiento se pausa al editar para conservar el cursor y la posición visible.", .english: "Following pauses while editing to preserve the cursor and visible position.", .french: "Le suivi se met en pause pendant la modification pour conserver le curseur et la position visible."],
        LocalizationKey.livePaused.rawValue: [.spanish: "Seguimiento pausado para que puedas revisar el texto.", .english: "Following is paused so you can review the text.", .french: "Le suivi est en pause pour vous permettre de relire le texte."],
        LocalizationKey.liveFollowAction.rawValue: [.spanish: "Seguir en vivo", .english: "Follow live", .french: "Suivre en direct"],
        LocalizationKey.liveCorrectionsKept.rawValue: [.spanish: "Tus correcciones se conservaron. Puedes compararlas con la transcripción final en las otras pestañas.", .english: "Your corrections were preserved. You can compare them with the final transcript in the other tabs.", .french: "Vos corrections ont été conservées. Vous pouvez les comparer à la transcription finale dans les autres onglets."],
        LocalizationKey.liveFinalReplaced.rawValue: [.spanish: "La versión final reemplazó la provisional; puedes editar y exportar el texto.", .english: "The final version replaced the provisional one; you can edit and export the text.", .french: "La version finale a remplacé la version provisoire ; vous pouvez modifier et exporter le texte."],
        LocalizationKey.professorUnavailable.rawValue: [.spanish: "Aún no hay profesor seleccionado; se muestra la transcripción completa.", .english: "No professor is selected yet; the full transcript is shown.", .french: "Aucun professeur n’est encore sélectionné ; la transcription complète est affichée."],
        LocalizationKey.copyTranscript.rawValue: [.spanish: "Copiar transcripción", .english: "Copy transcript", .french: "Copier la transcription"],
        LocalizationKey.copyForChatGPT.rawValue: [.spanish: "Copiar para ChatGPT", .english: "Copy for ChatGPT", .french: "Copier pour ChatGPT"],
        LocalizationKey.openTextFile.rawValue: [.spanish: "Abrir archivo de texto", .english: "Open text file", .french: "Ouvrir le fichier texte"],
        LocalizationKey.showFolder.rawValue: [.spanish: "Mostrar carpeta en Finder", .english: "Show folder in Finder", .french: "Afficher le dossier dans le Finder"],
        LocalizationKey.exportAction.rawValue: [.spanish: "Exportar {{kind}}", .english: "Export {{kind}}", .french: "Exporter {{kind}}"],
        LocalizationKey.actions.rawValue: [.spanish: "Acciones", .english: "Actions", .french: "Actions"],
        LocalizationKey.hide.rawValue: [.spanish: "Ocultar", .english: "Hide", .french: "Masquer"],
        LocalizationKey.reviewEmptyTitle.rawValue: [.spanish: "Nada para revisar", .english: "Nothing to review", .french: "Rien à vérifier"],
        LocalizationKey.reviewEmptyDescription.rawValue: [.spanish: "Los fragmentos con baja confianza o voces superpuestas aparecerán aquí.", .english: "Low-confidence or overlapping-voice fragments will appear here.", .french: "Les fragments à faible confiance ou avec des voix superposées apparaîtront ici."],
        LocalizationKey.reviewAssign.rawValue: [.spanish: "Asignar al profesor", .english: "Assign to professor", .french: "Attribuer au professeur"],
        LocalizationKey.reviewAssigned.rawValue: [.spanish: "Asignado al profesor ✓", .english: "Assigned to professor ✓", .french: "Attribué au professeur ✓"],
        LocalizationKey.reviewDescription.rawValue: [.spanish: "Revisa solapamientos o asignaciones dudosas. Marca los fragmentos que pertenecen al profesor.", .english: "Review overlaps or uncertain assignments. Mark fragments that belong to the professor.", .french: "Vérifiez les chevauchements ou attributions incertaines. Marquez les fragments qui appartiennent au professeur."],
        LocalizationKey.speakerUnknown.rawValue: [.spanish: "Persona desconocida", .english: "Unknown person", .french: "Personne inconnue"],
        LocalizationKey.speakerPerson.rawValue: [.spanish: "Persona {{number}}", .english: "Person {{number}}", .french: "Personne {{number}}"],
        LocalizationKey.speakerProfessor.rawValue: [.spanish: "Profesor", .english: "Professor", .french: "Professeur"],
        LocalizationKey.speakerParticipant.rawValue: [.spanish: "Participante", .english: "Participant", .french: "Participant"],
        LocalizationKey.modeOnlineMetadata.rawValue: [.spanish: "Clase online", .english: "Online class", .french: "Cours en ligne"],
        LocalizationKey.modeInPersonMetadata.rawValue: [.spanish: "Clase presencial", .english: "In-person class", .french: "Cours en présentiel"],
        LocalizationKey.exportSubject.rawValue: [.spanish: "Materia", .english: "Subject", .french: "Matière"],
        LocalizationKey.exportDate.rawValue: [.spanish: "Fecha", .english: "Date", .french: "Date"],
        LocalizationKey.exportDuration.rawValue: [.spanish: "Duración", .english: "Duration", .french: "Durée"],
        LocalizationKey.exportMode.rawValue: [.spanish: "Modo", .english: "Mode", .french: "Mode"],
        LocalizationKey.exportSource.rawValue: [.spanish: "Fuente", .english: "Source", .french: "Source"],
        LocalizationKey.exportTranscript.rawValue: [.spanish: "Transcripción", .english: "Transcript", .french: "Transcription"],
        LocalizationKey.exportProvisionalDuration.rawValue: [.spanish: "Duración provisional", .english: "Provisional duration", .french: "Durée provisoire"],
        LocalizationKey.exportKindTXT.rawValue: [.spanish: "TXT", .english: "TXT", .french: "TXT"],
        LocalizationKey.exportKindMarkdown.rawValue: [.spanish: "Markdown", .english: "Markdown", .french: "Markdown"],
        LocalizationKey.exportKindSRT.rawValue: [.spanish: "SRT", .english: "SRT", .french: "SRT"],
    ]
}

enum SpeakerPresentation {
    static func localizedName(
        id: String,
        storedDisplayName: String? = nil,
        language: ResolvedInterfaceLanguage,
    ) -> String {
        let raw = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = raw.lowercased()
        let unknownNames = [
            "persona desconocida",
            "person unknown",
            "personne inconnue",
            "unknown person",
            "unknown speaker",
        ]
        if unknownNames.contains(normalized) {
            return ClassScribeLocalization.text(.speakerUnknown, language: language)
        }

        let parts = raw.split(whereSeparator: { $0 == " " || $0 == "_" || $0 == "-" })
        if parts.count == 2,
           let number = Int(parts[1]),
           ["persona", "person", "personne", "speaker"].contains(parts[0].lowercased())
        {
            return ClassScribeLocalization.text(
                .speakerPerson,
                language: language,
                arguments: ["number": String(number)],
            )
        }

        if normalized == "profesor" || normalized == "professor" || normalized == "professeur" {
            return ClassScribeLocalization.text(.speakerProfessor, language: language)
        }
        if normalized == "participante" || normalized == "participant" {
            return ClassScribeLocalization.text(.speakerParticipant, language: language)
        }
        return storedDisplayName ?? id
    }
}

enum ReviewReasonPresentation {
    static func localized(
        _ reason: String,
        language: ResolvedInterfaceLanguage,
    ) -> String {
        let normalized = reason.lowercased()
        if normalized.hasPrefix("voces superpuestas")
            || normalized.hasPrefix("overlapping voices")
            || normalized.hasPrefix("voix superposées")
        {
            return language == .spanish
                ? "Voces superpuestas; confirmar manualmente"
                : language == .french
                    ? "Voix superposées ; confirmer manuellement"
                    : "Overlapping voices; confirm manually"
        }
        if let open = reason.lastIndex(of: "("), reason.hasSuffix(")") {
            let score = String(reason[reason.index(after: open) ..< reason.index(before: reason.endIndex)])
            return switch language {
            case .spanish: "Confianza de hablante baja (\(score))"
            case .english: "Low speaker confidence (\(score))"
            case .french: "Faible confiance du locuteur (\(score))"
            }
        }
        return reason
    }
}
