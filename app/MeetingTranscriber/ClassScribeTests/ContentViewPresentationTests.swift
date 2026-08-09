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
}
