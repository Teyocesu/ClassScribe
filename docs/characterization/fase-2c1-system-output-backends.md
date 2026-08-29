# Caracterización Fase 2C.1 — backends de audio del equipo

Fecha: 2026-08-25

Baseline correctivo final: `v0.8.0-development` = `524319e579e954fc374b07c95ab917f1bd53fe3c`
Estado final: revisión independiente **APPROVED**; arquitectura/backend/lifecycle
local **APPROVED**; Windows W0/W1A/W1B runtime y gates físicos **PASS**;
macOS CATap global/TCC y hardware/device-change permanecen **PENDING**. Esto no implica release readiness completo; la UX de
Fase 2C.2 se documenta separadamente en
[`fase-2c2-system-output-consent.md`](fase-2c2-system-output-consent.md).

## Alcance

Fase 2C.1 agrega únicamente la infraestructura para capturar el output del
sistema. No agrega selector visible, modal, CTA, fallback automático ni cambio
de backend cuando una aplicación falla. La UI normal continúa usando
`CaptureScope.application` para online y `CaptureScope.microphone` para
presencial. El scope persistido `systemOutput` ya existente se conserva sin
inventar un nuevo `CaptureMode`.

La base correctiva fue verificada antes del cambio con:

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

En el estado de 2C.1 la única emisión disponible era el seam interno de tests y
la futura capa de consentimiento. La emisión productiva de 2C.2 está descrita en
la caracterización separada. Por eso una sesión histórica puede conservar `captureScope: systemOutput`, pero
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
son seams inspeccionables y testeables. `AppAudioCapture` conserva la política
`.systemOutput`, no un snapshot de `AudioObjectID`: cada construcción inicial o
restart vuelve a enumerar ClassScribe y los helpers rooted en el bundle,
deduplica PIDs/objetos y exige el round-trip PID → objeto → PID. Un fallo de
traducción no fabrica IDs sintéticos.

El source global reutiliza `AudioCaptureSession`, el `source.raw` de la sesión,
el `TimelineAnchor` y el `LiveAudioSink`. Todas las mutaciones nativas de
`AppAudioCapture` viven en un `lifecycleQueue` serial; el listener entregado en
main sólo notifica y encola. Stop, cambio de dispositivo y retry comparten ese
owner; se invalida la generación antes del teardown, se drenan callbacks y
`writeQueue` antes de destruir CoreAudio, y los retries delayed no pueden
recrear la fuente después de Stop. No se crea otro archivo ni otra sesión.

Si el coordinador agota retries, la fuente publica un error terminal observable
por `CaptureNativeLevelSnapshot`; `CaptureController` lo consume como fallo
recuperable y conserva el audio durable. Un restart exitoso limpia ese error y
un intento nuevo no hereda el estado anterior.

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
endpoint actual. La sesión se considera activa por el intento, raw/channel/
writer y admission state, no por la existencia temporal del recorder.
`StopAsync` es single-flight: durante un rebind sin recorder cancela capture,
invalida generación/coordinador/autorización, termina el recorder si existe,
espera writer/raw y finaliza el `source.raw` existente. El task compartido se
publica bajo el mismo lock antes de que el caller owner salga; ningún follower
ejecuta teardown o finalización propia y todos reciben el mismo resultado/error.
El stop incompleto también mantiene ownership de sesión durante la ventana
`FinishCaptureResourcesAsync → FinalizeRawAsync`; sólo un Start posterior a la
finalización completada puede limpiar el task terminado. La ruta cruda se
captura por intento y no depende de un campo que un Start siguiente pueda
reemplazar. Toda publicación final de una nueva generación revalida Stop,
intento, generación y coordinator. El mensaje de no-callback para esta fuente
nombra explícitamente la salida del sistema.

La frontera process-loopback adopta el recorder construido sólo después de
revalidar cancelación y dispone el recurso nativo si esa cancelación gana
después de `BuildAsync`; no se cambia la identidad strong, la generación ni la
semántica `WithProcessLoopback`.

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
- política Windows de restart sólo ante cambio de endpoint ID;
- ownership de sesión Windows durante rebind sin recorder, Stop concurrente,
  fallo de build y recuperación, usando la fábrica de recorder del camino de
  producto;
- `concurrentStopCallsShareOneFinalization`,
  `concurrentStopFollowersReceiveSameWavePath`,
  `concurrentStopDoesNotDoubleDisposeRawWriter`,
  `startRejectedWhileStopFinalizationIsInProgress` y
  `nextStartAllowedAfterStopFinalizationCompletes` sobre el product path;
- cleanup post-`BuildAsync` con
  `processLoopbackBuiltRecorderIsDisposedWhenCancellationWinsAfterBuild`;
- serialización real del owner macOS, revalidación de self-exclusions en un
  restart y rechazo de traducciones sin objeto válido.

La validación Windows posterior a W1B fue: 194/194 tests, 0 failed, 0 skipped,
build sin warnings/errores, publish, PE/native y worker smoke **PASS**.

System output físico Windows: default Multimedia render endpoint y WASAPI
loopback reales; endpoint A → B conservó la misma sesión/master, sin nueva
autorización durante el rebind, con Stop y shutdown **PASS**.

`git diff --check` pasa. La última corrida del gate reproducible
`./scripts/pre-push.sh --with-tests` compiló el producto macOS y ejecutó 227
tests, incluidos los nuevos tests de lifecycle/self-exclusion, con resultado
**PASS**. Durante la caracterización hubo flakes aislados de timing en tests
process-backed preexistentes; sus reruns focalizados pasaron y no se atribuyen
a esta fase.

La suite standalone XCTest de `tools/audiotap` queda **SKIPPED** en este host:
el SwiftPM del Command Line Tools no acepta el parámetro existente
`swiftLanguageModes: [.v6]` del manifest antes de llegar al test target, y el
host no expone un gate XCTest standalone utilizable. Sus fuentes de producto
sí compilan dentro del toolchain oficial del repositorio. No se modificó el
manifest ni se instaló otra toolchain.

La suite Windows de product path vive en
`app/ClassScribe.Windows/tests/ClassScribe.Windows.Tests` y usa una fábrica
inyectable sobre el mismo `WindowsAudioCapture`; no usa una máquina de estados
paralela. W0 ejecutó restore/build/tests con el SDK canónico 10.0.302 y W1A/W1B
validaron el runtime físico, system output, endpoint change, rebind, Stop y
shutdown. El resultado Windows fue **PASS**.

## Gates pendientes y fuera de alcance

El gate físico macOS para CATap global — output audible real, exclusión de
ClassScribe, cambio de default output y teardown sin callbacks posteriores — no
se ejecutó en esta sesión. Tampoco se ejecutó el gate TCC ni el gate físico de
hardware/device-change. Estos estados son `SKIPPED/PENDING`, no PASS.

La UI de consentimiento explícito y el CTA de Fase 2C.2 están descritos en la
caracterización separada. La fidelidad master source-rate/stereo frente al derivado ASR 16 kHz mono,
el contenedor largo RF64/W64 o segmentación también permanecen diferidos.
