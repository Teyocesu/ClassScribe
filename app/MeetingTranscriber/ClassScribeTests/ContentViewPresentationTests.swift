import Testing
@testable import ClassScribe

@Test("El CTA principal siempre representa la operación activa")
func primaryCaptureControlState() {
    #expect(CapturePrimaryControlState.resolve(
        isStopping: true,
        isStarting: true,
        isRecording: true,
        isPaused: false,
        isProcessing: true,
    ) == .stopping)
    #expect(CapturePrimaryControlState.resolve(
        isStopping: false,
        isStarting: true,
        isRecording: false,
        isPaused: false,
        isProcessing: true,
    ) == .starting)
    #expect(CapturePrimaryControlState.resolve(
        isStopping: false,
        isStarting: false,
        isRecording: true,
        isPaused: true,
        isProcessing: false,
    ) == .recording(paused: true))
    #expect(CapturePrimaryControlState.resolve(
        isStopping: false,
        isStarting: false,
        isRecording: false,
        isPaused: false,
        isProcessing: true,
    ) == .processing)
    #expect(CapturePrimaryControlState.resolve(
        isStopping: false,
        isStarting: false,
        isRecording: false,
        isPaused: false,
        isProcessing: false,
    ) == .ready)
}

@Test("El inicio deshabilitado explica exactamente qué falta")
func captureStartGuidance() {
    let missingSubject = CaptureStartGuidance.resolve(
        subject: "  \n",
        mode: .online,
        hasSelectedSource: false,
    )
    #expect(missingSubject == .subjectRequired)
    #expect(missingSubject.message == "Escribe el nombre de la materia.")

    let missingApplication = CaptureStartGuidance.resolve(
        subject: "Álgebra",
        mode: .online,
        hasSelectedSource: false,
    )
    #expect(missingApplication == .sourceRequired(.online))
    #expect(missingApplication.message == "Elige la aplicación donde está la clase.")

    let missingMicrophone = CaptureStartGuidance.resolve(
        subject: "Álgebra",
        mode: .inPerson,
        hasSelectedSource: false,
    )
    #expect(missingMicrophone == .sourceRequired(.inPerson))
    #expect(missingMicrophone.message == "Elige el micrófono que quieres usar.")

    let ready = CaptureStartGuidance.resolve(
        subject: "Álgebra",
        mode: .inPerson,
        hasSelectedSource: true,
    )
    #expect(ready == .ready)
    #expect(ready.message == nil)

    let readyForSystemOutput = CaptureStartGuidance.resolve(
        subject: "Álgebra",
        mode: .online,
        hasSelectedSource: true,
    )
    #expect(readyForSystemOutput == .ready)
    #expect(OnlineCaptureSource.application.displayName == "Una aplicación")
    #expect(OnlineCaptureSource.systemOutput.displayName == "Audio del equipo")
}

@Test("El seguimiento en vivo distingue observación, edición y texto pendiente")
func liveTranscriptFollowPresentation() {
    let following = LiveTranscriptFollowPresentation.resolve(
        isFollowing: true,
        isEditing: false,
        hasUnseenText: false,
    )
    #expect(following.actionTitle == nil)
    #expect(following.message.contains("automáticamente"))

    let editing = LiveTranscriptFollowPresentation.resolve(
        isFollowing: false,
        isEditing: true,
        hasUnseenText: false,
    )
    #expect(editing.actionTitle == "Seguir en vivo")
    #expect(editing.message.contains("cursor"))

    let reviewing = LiveTranscriptFollowPresentation.resolve(
        isFollowing: false,
        isEditing: false,
        hasUnseenText: false,
    )
    #expect(reviewing.actionTitle == "Seguir en vivo")
    #expect(reviewing.message.contains("pausado"))

    let unseen = LiveTranscriptFollowPresentation.resolve(
        isFollowing: false,
        isEditing: true,
        hasUnseenText: true,
    )
    #expect(unseen.actionTitle == "Ver texto nuevo")
    #expect(unseen.message.contains("no se movieron"))
}
