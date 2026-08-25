# Fase 2A — Capture health y clasificación de señal

Fecha: 2026-08-25
Alcance: separación de salud del transporte/señal respecto de
`CapturePhase`, `AsrPhase` y `SessionPhase`, con integración en las rutas activas
macOS y Windows. No incluye VAD, una política general de aceptación ASR,
captura global, cambios de persistencia ni un nuevo gate físico.

## Estado

**PHASE 2A FIXED / PARTIAL**

Los hallazgos de revisión de Fase 2A están corregidos. El build release macOS y
la compilación estricta de tests pasan; el focused relevante ejecutó 24 tests,
incluidos el gate de ASR vacío/aceptado, la presentación de señal y los tests de
captura nativa. La suite completa Swift ejecutó 183 tests con **PASS**; sus
gates físicos/modelos explícitamente condicionados continúan skipped. Windows
tiene el tracker, el adaptador WASAPI y los tests MSTest escritos, pero el
runtime queda **SKIPPED — dotnet unavailable** en este host.

Los gates físicos existentes no cambian: CATap de aplicación macOS continúa
**PASS** según Fase 1C; micrófono macOS continúa **SKIPPED — TCC**; Windows
físico/runtime continúa **SKIPPED — PHYSICAL WINDOWS / dotnet unavailable**.

## Modelo estructurado

`CaptureSignalState` es un eje runtime independiente:

| Estado | Evidencia | Salud del transporte | Acción 2A |
| --- | --- | --- | --- |
| `awaitingCallbacks` | aún no llegó callback y no venció el presupuesto inicial | indeterminada | esperar sin declarar grabación saludable |
| `noCallbacks` | no llegó callback inicial a tiempo o el último callback quedó stale más que el stall budget | no | diagnosticar/fallar la captura según el adaptador; conservar lo recibido |
| `silent` | llegaron callbacks, pero la energía está en o debajo del floor | sí | mantener captura; el silencio no es un fallo |
| `audible` | llegó energía por encima del floor | sí | reportar audio; no inferir voz, idioma ni ASR |

Un callback cuenta como evidencia aunque tenga cero frames o muestras digitales
cero. La transición `audible → silent` es válida y saludable. Sólo la ausencia
de callbacks puede producir `noCallbacks`; RMS no se usa como prueba de vida.
`hasReceivedCallbacks`/`HasReceivedCallbacks` es únicamente evidencia de que
existió un callback; no se expone un booleano `transportIsHealthy` que mezcle
espera, stall y contenido. El estado enum es la clasificación autoritativa.

Cada snapshot contiene `SessionAttemptID`, timestamps monotónicos de inicio y
último callback, conteos acumulados de callbacks/muestras/frames, RMS, energía
dBFS y edades calculadas. Los snapshots son diagnóstico runtime: los tiempos
monotónicos no se persisten en metadata de sesión. No se tocó el lector de
sesiones históricas ni se cambió el audio, el transcript original o las
correcciones humanas. Los waits de startup/stall y el wait legacy del
micrófono usan relojes monotónicos; `Date` queda fuera de los deadlines de
salud.

## Umbrales y calibración

Los números están centralizados en `CaptureSignalThresholds`. Se reutilizan
presupuestos ya presentes en el comportamiento/fixtures macOS; el floor
`-43 dBFS` coincide con el floor de análisis de silencio existente.

| Adaptador | Callback inicial | Stall | Silencio `≤ dBFS` | Evidencia |
| --- | ---: | ---: | ---: | --- |
| macOS aplicación | 30 s | 12 s | -43 | timeout de primer buffer/route negotiation y watchdog previo; floor de `recentSilenceDuration` |
| macOS micrófono | 2.5 s | 12 s | -43 | wait legacy de primer buffer y mismo floor de silencio |
| Windows WASAPI | 10 s | 12 s | -43 | timeout de primer paquete existente; stall/floor alineados al contrato común |
| tests | 5 s | 3 s | -40 | reloj falso, sin sleeps largos |

`-43 dBFS` es provisional: falta un corpus físico calibrado por dispositivo,
ruta y ruido de fondo. No hay hysteresis de VAD en esta fase. Ajustar un número
no sustituye la calibración pendiente.

## Integración macOS

La ruta activa queda:

`CaptureNativeExecutor → live sink → CaptureSignalHealthTracker → snapshot/control plane`.

`CaptureSignalHealthTracker` es lock-protected y se crea por intento. El sink
comprueba `CaptureAttemptGate`, mide el callback y publica al `AsyncStream` sin
esperar actor, `MainActor`, archivo, timer o recurso nativo. La ruta online
espera el primer callback. La ruta de micrófono sigue siendo MainActor-owned y
conserva `MicCaptureHandler.waitForFirstBuffer()`: sólo publica `isCapturing`
después de que un número de frames real llegó al escritor WAV. El tracker, sin
embargo, observa todos los callbacks; un callback de cero frames puede
clasificarse como `silent`, pero por sí solo no abre la grabación. PCM silencioso
con frames escritos sí satisface el gate de durabilidad y `terminalError`/los
diagnósticos de la espera se conservan.

Durante una captura, el timer refresca el snapshot. `silent` y `audible` no
terminalizan. Un stall `noCallbacks` queda como fallo de salud de captura y el
audio recibido sigue la ruta normal de recuperación/finalización.

## Integración Windows

`WindowsAudioCapture` reduce cada paquete WASAPI a `CaptureSignalMeasurement`
(PCM16, muestras, frames, RMS y dBFS), actualiza el tracker con el
`SessionAttemptID` del callback y publica `SignalHealthChanged`. Un paquete
vacío cuenta como primer callback silencioso. `MainViewModel` conecta el evento
mediante el `SessionAttemptCallbackLease`, aplica sólo snapshots del intento
actual y mantiene mensajes distintos para espera, stall, silencio y audio.
La observación y la presentación están separadas: un estado observado antes de
`IsRecording = true` no se marca como presentado, y el siguiente snapshot del
intento se presenta al comenzar la grabación aunque el estado no haya cambiado.
No se fuerza una abstracción de captura idéntica a macOS.

## Seguridad de intentos y ASR

El update de ownership y medición es una sección crítica: un callback A tardío
es rechazado después de `begin(B)` y no puede incrementar los contadores de B.
Cada nuevo intento parte en `awaitingCallbacks` con conteos y timestamps nuevos.
Al cancelar o detener se invalida el tracker; el último snapshot se conserva
sólo para diagnóstico del intento terminado.

La clasificación no modifica `AsrPhase`. En macOS, un resultado ASR se recorta
antes de aceptarse: sólo texto no vacío publica `transcribing`. Un resultado
vacío o whitespace es una inspección exitosa sin texto; confirma el cursor de
esa ventana para no reintentarlo indefinidamente, mantiene la captura, evita el
mensaje de texto actualizado y vuelve a `waitingForSpeech`. La salud de captura
no se altera; `audible` significa energía, no voz.

## Voz/VAD diferido

RMS/energía distingue silencio aproximado de señal material, pero no distingue
voz de música, ruido, notificaciones o una clase sin habla. Por eso esta fase
no agrega `voice`, VAD, hysteresis, ventanas mínimas, forced language ni
políticas de aceptación ASR. El estado de voz/VAD y el gate de no-speech quedan
explícitamente diferidos a Fase 3, tal como exige la SPEC.

## Evidencia ejecutada

- `./scripts/pre-push.sh --with-tests`: build release macOS, compilación Swift
  estricta y suite completa **PASS (183 tests)**. Los skips reportados son gates
  físicos/modelos existentes, no fallos de Fase 2A.
- Focused Swift con toolchain local: **PASS (24 tests)**, incluyendo las diez
  invariantes de salud, `emptyLiveAsrResultDoesNotPublishTranscribing`,
  `acceptedLiveAsrResultPublishesTranscribing` y los tests de ejecución/cancelación
  de captura nativa.
- Gate AudioTap de micrófono: `MicFirstBufferGateTests` mantiene cobertura
  determinista de que cero frames no abre el gate y frames reales, aun con
  energía silenciosa, sí lo abren. La ejecución directa del paquete AudioTap
  queda **SKIPPED — host CLT no expone XCTest compatible con este manifest**;
  no se presenta como gate físico.
- Tests Windows `CaptureSignalHealthTests.cs`: escritos, no ejecutados;
  `dotnet`, `csc`, `mcs`, `csi` y `msbuild` no están disponibles.
- No se ejecutaron GitHub Actions, PRs, tags, releases ni gates físicos nuevos.
