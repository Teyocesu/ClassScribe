# Caracterización de Fase 2B.2 — rebind de source durante una grabación

Estado: **PHASE 2B.2 FIXED / PARTIAL — blockers finales de revisión corregidos**.

La implementación cubre el rebind de la encarnación nativa de una aplicación
durante una misma sesión. El intento de sesión, el audio durable, el timeline
en vivo y el cursor ASR permanecen estables; sólo se reemplaza el source nativo
que entrega callbacks.

## Identidad y ownership

`CaptureSourceGeneration` contiene el `SessionAttemptID` y un contador
monótono de source dentro de ese intento. `CaptureSourceGenerationGate` es
independiente de `CaptureAttemptGate`/`SessionAttemptID`: un callback del source
A queda rechazado inmediatamente después de `advance`, aunque pertenezca al
mismo intento de sesión. `invalidate` rechaza también callbacks, completions y
publicaciones posteriores a Stop o a la sustitución de la sesión.

`CaptureRebindCoordinator` es single-flight por intento. Mantiene el owner de
la operación y rechaza una segunda operación concurrente; cancelación y
deadline permanecen en la operación llamadora. No se introduce una mega-enum
de lifecycle.

El rebind online tiene una cancelación de ciclo de vida propia
(`onlineRebindCancellation`), separada de la cancelación de startup. Stop,
cancelación y sustitución de sesión invalidan la generación y cancelan tanto
el task como esa espera. Las precondiciones del producto se validan antes de
adquirir el owner del coordinator, por lo que una entrada inválida no deja
ownership huérfano.

Cada source generation inicia un `CaptureSignalHealthTracker` nuevo en
`awaitingCallbacks`. El callback comprueba intento y generation antes de
actualizar salud, nivel, first-callback, live store o cola durable. Un evento
`stopped` tardío de la generación anterior sólo puede liberar su waiter local;
no puede fallar ni mutar la generación nueva.

## macOS

La reconciliación usa la identidad lógica de 2B.1 y vuelve a validar los
targets de audio antes del handoff CATap. La política compara el conjunto de
AudioObjectIDs/PIDs validados, no el orden. Rebind sólo se solicita por:

- reemplazo de root con identidad fuerte;
- cambio material del conjunto validado de helpers/targets;
- recuperación acotada de callbacks sin asumir que una identidad débil puede
  reasignarse.

Un resultado `missing` o `ambiguous` conserva el source actual mientras la
fuente sigue sana y no elige una aplicación por nombre. Antes de detener el
tap se confirma de nuevo la identidad/topología; si la observación vuelve al
estado original, se abandona el rebind sin tocar el tap sano. El orden
destructivo es explícito: se detiene y drena la generación vieja mientras aún
es la actual; sólo después se avanza la generación, se crea salud fresca y se
resuelve/construye/inicia el siguiente tap. Una identidad débil no hace
auto-rebind. Si el stop/drain ya ocurrió y la resolución o el build fallan, el
control plane marca explícitamente la fuente como no disponible y mantiene una
recuperación acotada; no presenta `isCapturing` sin tap como estado sano.

`AudioCaptureSession` es ahora el owner de la salida durable y del timeline.
`source.raw` se crea y abre una sola vez. `replaceApplicationCapture` cierra la
admisión, drena el callback IOProc/writeQueue completo antes de
`AudioDeviceStop`, reutiliza el mismo descriptor y crea el siguiente
`AppAudioCapture` con el mismo `TimelineAnchor`. No se trunca ni se crea otro
`source.raw`; el gap se representa como silencio según los timestamps host del
source. Un callback admitido que se vuelve stale mientras resamplea ya no puede
escribir el archivo ni alimentar el live store. El live store y su generación
lógica no se reinician.

El driver de rebind es un seam de producto: el default delega al
`CaptureNativeExecutor` serial real, mientras las pruebas inyectan un driver
que ejecuta la misma decisión de controller → stop → start sin crear CATap.

## Windows

`WindowsAudioCapture` separa el stream/file/channel/writer de sesión del
`WasapiRecorder`, handlers, first-callback y salud de cada source generation.
La frontera `BuildProcessLoopbackIfCurrentSourceGenerationAsync` se ejecuta
justo antes de `WithProcessLoopback`/`BuildAsync`; un Stop o generation stale no
puede publicar el recorder construido. La resolución conserva precedencia del
incumbent PID: un sibling con la misma identidad no provoca rebind mientras el
root actual siga vivo; replacement ambiguo o weak no construye recorder.

El rebind cierra la admisión y drena el callback viejo antes de detener y
disponer su recorder; la generación vieja permanece actual durante todo ese
stop/drain. Conserva el mismo `source.raw`/writer, avanza la generación y arma
el handoff sólo después del drain, vuelve a resolver y revalida el root antes
de construir la nueva encarnación. `CaptureHandoffTimeline` toma
`Stopwatch.GetTimestamp()` únicamente en el primer callback no vacío aceptado
de la nueva generación: el gap se mide desde el final durable de N hasta la
llegada de ese PCM, por lo que incluye resolve/build/start/first-callback.
Los callbacks normales de una misma generación nunca rellenan jitter; un
callback vacío no consume el gap y un callback stale no puede consumirlo. El
silencio se escribe en chunks acotados. El presupuesto de 30 s aplica al gap
total: si se supera, produce un fault explícito y detiene la captura; no se
devuelve `0` fingiendo éxito.

El seam de writer se usa desde `WindowsAudioCapture` y cubre también el
segundo gate de callback antes de encolar el paquete durable. No requiere
WASAPI físico para probar la transición de generación.

## Race review

Se revisaron explícitamente las parejas callback viejo/stop-drain/advance,
start nuevo/Stop, completion de rebind/sesión siguiente, timer de salud/
generation y stopped viejo/source nuevo. No se mantienen locks mientras se
llaman APIs nativas de start/stop, se espera un callback o se hace I/O de
archivo. macOS serializa setup/stop/rebind y drena el IOProc/writeQueue antes
de publicar la siguiente generación; Windows cierra su lease de callback antes
de detener/publicar. Los seams de producto cubren un callback viejo pausado:
no se publica N+1 hasta completar el drain y no quedan mutaciones stale de
salud, nivel o writer después del cambio.

## Seams de ciclo de vida cubiertos

Los tests de producto ejercitan `CaptureController` hasta la decisión y el
driver de stop/start: startup cleanup no deshabilita un rebind posterior,
prerrequisitos fallidos no filtran ownership, Stop cancela la espera del
primer callback, una aparición transitoria del helper no destruye el tap, una
topología que vuelve después del stop arranca una fuente nueva, una resolución
post-stop fallida deja una recuperación explícita sin fuente nativa saludable
y un stop/drain pausado no permite publicar N+1 antes de liberar callbacks
viejos (`pausedMacCallbackCannotWriteOrPublishAfterGenerationSwitch`). En
Windows, los tests ejercitan `CaptureHandoffTimeline`, el lease de callback,
el gap hasta el primer PCM (`handoffGapIncludesResolveBuildAndFirstCallbackDelay`),
el fault sobre 30 s (`buildDelayBeyondSafetyBoundProducesExplicitFault`) y el
writer boundary usado por `WindowsAudioCapture`
(`pausedWindowsCallbackCannotMutateHealthLevelOrWriterAfterGenerationSwitch`).

## Evidencia local

- `./scripts/pre-push.sh --with-tests`: **PASS — 221 tests macOS**.
- `git diff --check` sobre archivos intencionales: **PASS**.
- Build release de ClassScribe: **PASS**.
- Fuentes AudioTapLib: compiladas dentro del build/test target de ClassScribe.
- Suite independiente de `tools/audiotap`: **SKIPPED / BLOCKED — el CLT local
  no expone el módulo XCTest**; no se modificó el toolchain del sistema.
- Windows runtime/tests físicos: **SKIPPED — `dotnet`/`csc` no disponibles**.
- Gate físico de reemplazo PID/helper durante una clase real: **PENDING**; no
  se presenta como PASS sin una aplicación reproducible que pueda reemplazar
  root/helpers y conservar AudioObjectIDs observables.

La evidencia demuestra la frontera de ownership, el policy de detección, la
continuidad durable y los races deterministas mediante seams de producto. No
certifica todavía el lifecycle físico Windows ni el reemplazo PID físico
macOS; esos gates siguen pendientes y no se presentan como PASS.
