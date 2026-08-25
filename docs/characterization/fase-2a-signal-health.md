# Fase 2A — Capture health y clasificación de señal

Fecha: 2026-08-24
Alcance: separación de salud del transporte/señal respecto de
`CapturePhase`, `AsrPhase` y `SessionPhase`, con integración en las rutas activas
macOS y Windows. No incluye VAD, aceptación ASR, captura global, cambios de
persistencia ni un nuevo gate físico.

## Estado

**PHASE 2A PARTIAL**

La implementación y el build release macOS están completos. El harness
focalizado ejecutó las diez invariantes de clasificación. La suite completa de
Swift no llegó a ejecutar por un error preexistente de Swift 6 estricto en
`CaptureNativeExecutionTests.swift:112` (`Thread.isMainThread` no está
disponible en un contexto async). Windows tiene el tracker, el adaptador WASAPI
y los tests MSTest escritos, pero el runtime queda
**SKIPPED — dotnet unavailable** en este host.

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
esperar actor, `MainActor`, archivo, timer o recurso nativo. El startup espera
el primer callback, no la primera muestra no vacía. El resampler y el handler
de micrófono también envían un callback vacío cuando el native path está vivo.
La ruta de micrófono sigue siendo MainActor-owned y conserva su setup/teardown
legacy; sólo comparte el tracker runtime.

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
No se fuerza una abstracción de captura idéntica a macOS.

## Seguridad de intentos y ASR

El update de ownership y medición es una sección crítica: un callback A tardío
es rechazado después de `begin(B)` y no puede incrementar los contadores de B.
Cada nuevo intento parte en `awaitingCallbacks` con conteos y timestamps nuevos.
Al cancelar o detener se invalida el tracker; el último snapshot se conserva
sólo para diagnóstico del intento terminado.

La clasificación no modifica `AsrPhase`. macOS y Windows siguen pasando a
`transcribing` únicamente después de aceptar un resultado ASR no vacío. Un
resultado ASR vacío no modifica la salud de captura. `audible` significa
energía, no voz.

## Voz/VAD diferido

RMS/energía distingue silencio aproximado de señal material, pero no distingue
voz de música, ruido, notificaciones o una clase sin habla. Por eso esta fase
no agrega `voice`, VAD, hysteresis, ventanas mínimas, forced language ni
políticas de aceptación ASR. El estado de voz/VAD y el gate de no-speech quedan
explícitamente diferidos a Fase 3, tal como exige la SPEC.

## Evidencia ejecutada

- `./scripts/pre-push.sh --with-tests`: build release macOS **PASS**; compiló
  el tracker y las rutas de AudioTap nuevas.
- Harness Swift aislado con toolchain local: **PASS (10 invariants)** para
  awaiting/no-callback inicial, callback cero, silencio continuo, audible,
  audible→silent, stall, A→B stale/fresh y ASR vacío.
- La compilación de tests macOS llegó a `CaptureSignalHealthTests.swift`, pero
  la suite no ejecutó por el error preexistente de
  `CaptureNativeExecutionTests.swift:112`.
- Tests Windows `CaptureSignalHealthTests.cs`: escritos, no ejecutados;
  `dotnet`, `csc`, `mcs`, `csi` y `msbuild` no están disponibles.
- No se ejecutaron GitHub Actions, PRs, tags, releases ni gates físicos nuevos.
