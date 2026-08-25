# Caracterización de Fase 2B.2 — rebind de source durante una grabación

Estado: **PHASE 2B.2 COMPLETE / PARTIAL**.

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

Un resultado `missing` o `ambiguous` conserva el source actual y no elige una
aplicación por nombre. Una identidad débil no hace auto-rebind. La ventana de
reconciliación y los intentos de recuperación son acotados; si no se recupera,
se conserva el audio parcial para la ruta de sesión recuperable.

`AudioCaptureSession` es ahora el owner de la salida durable y del timeline.
`source.raw` se crea y abre una sola vez. `replaceApplicationCapture` detiene y
drena completamente el CATap/IOProc anterior, reutiliza el mismo descriptor y
crea el siguiente `AppAudioCapture` con el mismo `TimelineAnchor`. No se
trunca ni se crea otro `source.raw`; el gap se representa como silencio según
los timestamps host del source, con límite contra saltos corruptos. El live
store y su generación lógica no se reinician.

## Windows

`WindowsAudioCapture` separa el stream/file/channel/writer de sesión del
`WasapiRecorder`, handlers, first-callback y salud de cada source generation.
La frontera `BuildProcessLoopbackIfCurrentSourceGenerationAsync` se ejecuta
justo antes de `WithProcessLoopback`/`BuildAsync`; un Stop o generation stale no
puede publicar el recorder construido. La resolución conserva precedencia del
incumbent PID: un sibling con la misma identidad no provoca rebind mientras el
root actual siga vivo; replacement ambiguo o weak no construye recorder.

El rebind detiene y dispone el recorder viejo, conserva el mismo
`source.raw`/writer, vuelve a resolver y revalida el root antes de construir la
nueva encarnación. Los callbacks aceptados calculan gaps con reloj monotónico y
añaden silencio PCM acotado antes del primer paquete nuevo; nunca se hace un
relleno no acotado por un timestamp corrupto.

## Race review

Se revisaron explícitamente las parejas callback viejo/advance-stop,
start nuevo/Stop, completion de rebind/sesión siguiente, timer de salud/
generation y stopped viejo/source nuevo. No se mantienen locks mientras se
llaman APIs nativas de start/stop, se espera un callback o se hace I/O de
archivo. El executor macOS sigue serializando setup/stop/rebind para que el
tap viejo se drene antes del nuevo; Windows mantiene el writer fuera del
lifecycle del recorder.

## Evidencia local

- `./scripts/pre-push.sh --with-tests`: **PASS — 214 tests macOS**.
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
continuidad durable y los races deterministas. No certifica todavía el
lifecycle físico Windows ni el reemplazo PID físico macOS.
