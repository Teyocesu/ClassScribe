# Caracterización Fase 2C.1 — backends de audio del equipo

Fecha: 2026-08-25

Baseline: `v0.8.0-development` = `21fa69bd56bfca2cad00c71491412c9673371b01`
Estado: infraestructura implementada; gate físico y runtime Windows pendientes.

## Alcance

Fase 2C.1 agrega únicamente la infraestructura para capturar el output del
sistema. No agrega selector visible, modal, CTA, fallback automático ni cambio
de backend cuando una aplicación falla. La UI normal continúa usando
`CaptureScope.application` para online y `CaptureScope.microphone` para
presencial. El scope persistido `systemOutput` ya existente se conserva sin
inventar un nuevo `CaptureMode`.

La base fue verificada antes del cambio con:

```text
git fetch origin
git switch v0.8.0-development
git status --short
git rev-parse HEAD
git rev-parse origin/v0.8.0-development
```

El árbol estaba limpio y `HEAD` coincidía con `origin/v0.8.0-development`.

## Frontera de autorización

`SystemOutputCaptureAuthorization` es un capability en memoria con nonce y
`SessionAttemptID`. La autoridad:

- acepta sólo el nonce emitido para el intento exacto;
- reemplaza el nonce anterior si se vuelve a emitir;
- invalida al cancelar, detener, reemplazar o fallar el intento;
- no implementa `Codable`, no lee un `Bool` de metadata y no tiene “recordar para siempre”;
- se comprueba en el boundary MainActor y nuevamente dentro del owner nativo.

La única emisión en 2C.1 es el seam interno de tests/futura capa de consentimiento.
Por eso una sesión histórica puede conservar `captureScope: systemOutput`, pero
esa metadata nunca autoriza una captura nueva.

La ruta de fallo de aplicación, `noCallbacks`, silencio o error no llama a este
seam ni modifica el scope. El fallback automático sigue siendo inalcanzable.

## macOS — CATap global

El target activo es `app/MeetingTranscriber/ClassScribeSources` y delega en el
package `tools/audiotap`. `AppAudioCaptureSource` separa explícitamente:

- aplicación: `CATapDescription(stereoMixdownOfProcesses:)`, con la traducción
  PID → AudioObjectID y el round-trip PID → objeto existente;
- sistema: `CATapDescription(stereoGlobalTapButExcludeProcesses:)`, con sólo
  los AudioObjectID validados de ClassScribe y sus helpers rooted en el bundle.

No se usa ScreenCaptureKit ni una lista de todas las aplicaciones como entrada
del tap global. Si CoreAudio no puede validar el proceso propio, no se fabrica
un ID: la exclusión queda limitada a los objetos que pasaron el round-trip.
`CATapDescriptionFactory` y `AppAudioCapture.systemOutputExclusionObjectIDs()`
son seams inspeccionables y testeables.

El source global reutiliza `AudioCaptureSession`, el `source.raw` de la sesión,
el timeline y el `LiveAudioSink`. `AppAudioCapture` conserva su listener y
coordinador de default-output: ante cambio de dispositivo cierra admisión,
drena callbacks, detiene/destroza el aggregate/tap y reintenta en el mismo
owner, sin crear otro archivo ni otra sesión.

El controlador conserva `SessionAttemptID`, `CaptureSourceGeneration`, el gate
de callbacks y los estados `awaitingCallbacks`, `noCallbacks`, `silent` y
`audible`. Un primer callback global se exige antes de publicar recording; no se
introduce VAD ni se confunde silencio digital con falta de transporte.

## Windows — WASAPI render loopback

El target activo es `app/ClassScribe.Windows`. `AudioSourceKind.SystemOutput` es
interno y no se enumera en la UI de 2C.1. El backend:

1. resuelve `MMDeviceEnumerator.GetDefaultAudioEndpoint(DataFlow.Render,
   Role.Multimedia)`;
2. conserva el `MMDevice.ID` como identidad de endpoint;
3. construye NAudio con `WithDevice(endpoint)`, `WithLoopbackCapture()`, shared
   mode, event sync, formato PCM existente y `Build()`;
4. entrega los callbacks al mismo lease/generation/timeline/writer que las
   demás fuentes.

No usa `WithProcessLoopback`, PID 0 ni una enumeración de todos los procesos.
El health tick hace una observación acotada del endpoint default con single
flight y throttle. Sólo un cambio del ID provoca rebind; un cambio de nombre no
lo provoca. El rebind cierra admisión y drena la generación vieja, conserva el
`source.raw`, marca el handoff en el timeline y crea el recorder loopback del
endpoint actual.

## Persistencia y ownership

La metadata de una sesión nueva usa el scope del `ClassSessionContext`; al abrir
historial se restaura `metadata.captureScope ?? metadata.mode.captureScope`.
No se reescriben sesiones históricas al abrirlas y se mantienen `source.raw`,
`source.wav`, la referencia al transcript ASR original y los overlays de
correcciones humanas.

## Evidencia local

Se añadieron pruebas deterministas para:

- autoridad por intento, reemplazo de nonce e invalidación en macOS y Windows;
- exigencia del capability antes del start macOS;
- construcción CATap global con exclusiones explícitas y construcción de app
  por mixdown de procesos;
- política Windows de restart sólo ante cambio de endpoint ID.

`git diff --check` pasa. El gate reproducible del repositorio
`./scripts/pre-push.sh --with-tests` terminó correctamente: compilación del
producto macOS y 224 tests focused/subsystem pasaron, incluidos los nuevos tests
de autorización y persistencia. El script usa el toolchain local versionado en
`.toolchain`.

La ejecución directa de `swift test` con el SwiftPM del Command Line Tools del
sistema quedó bloqueada porque esa versión rechaza el parámetro existente
`swiftLanguageModes: [.v6]` del manifest, antes de compilar el producto. No se
modificó el manifest ni se instaló otra toolchain; tampoco hay `xcodebuild`
disponible en el host. También se intentó la suite standalone de
`tools/audiotap` con el mirror local; sus fuentes de producto compilaron, pero
el host no expone el módulo `XCTest`, por lo que esa suite no pudo enlazarse.
Esto no invalida el gate del repositorio, que sí pasó.

La suite Windows está escrita en `ClassScribe.Core.Tests`, pero el runtime no se
ejecutó porque `dotnet`/`csc` no están disponibles. No se instala SDK ni se
presenta el runtime como aprobado.

## Gates pendientes y fuera de alcance

El gate físico macOS para CATap global — output audible real, exclusión de
ClassScribe, cambio de default output y teardown sin callbacks posteriores — no
se ejecutó en esta sesión. Tampoco se ejecutó el gate TCC ni el gate físico
Windows. Estos estados son `SKIPPED/PENDING`, no PASS.

Fase 2C.2 queda pendiente para conectar la UI de consentimiento explícito y el
CTA. La fidelidad master source-rate/stereo frente al derivado ASR 16 kHz mono,
el contenedor largo RF64/W64 o segmentación también permanecen diferidos.
