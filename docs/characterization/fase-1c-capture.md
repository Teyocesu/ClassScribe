# Fase 1C — Caracterización física y frontera de ejecución de captura

Fecha: 2026-08-24
Alcance: únicamente captura macOS de aplicación; sin Fase 2, system audio,
ASR, VAD, process isolation, release work ni cambios Windows.

## Estado

**PHASE 1C PARTIAL**

La corrección arquitectónica mínima quedó implementada para la ruta CATap de
aplicación. El setup/stop síncrono de `AudioCaptureSession` ya no se ejecuta
en MainActor y cada work handle lleva un `SessionAttemptID`. El camino físico
normal sigue bounded y no produjo callbacks después de stop; la decisión de
aislamiento de proceso continúa inconclusa porque no hay un fault gate físico
que demuestre una llamada CoreAudio real no cooperativa.

Micrófono permanece `SKIPPED — TCC` y Windows permanece
`SKIPPED — PHYSICAL WINDOWS / dotnet unavailable`. El checkbox físico de
`PLAN.md` sigue abierto.

## Execution boundary

La frontera nueva está en
`app/MeetingTranscriber/ClassScribeSources/CaptureNativeExecution.swift`:

- `CaptureNativeExecutor` posee una `DispatchQueue` serial dedicada;
- la cola posee `AudioCaptureSession` por `SessionAttemptID` hasta el stop real;
- registro CoreAudio, creación de `AudioCaptureSession.start()`,
  `AudioCaptureSession.stop()` y consulta de nivel de aplicación se ejecutan
  en esa cola;
- `CaptureNativeWork` separa el wait del caller de la vida de la operación:
  `cancel()` despierta al caller y marca stale, pero no finge interrumpir la
  llamada nativa;
- no se mantiene ningún lock durante start, stop, reads, writes, kill ni
  awaits.

`CaptureController` sigue siendo `@MainActor`, pero sólo coordina estado,
generation, callback gate, buffers y solicitudes. El pump de buffers y la
finalización WAV ya existentes conservan ownership explícito; no son la
llamada nativa CATap.

La ruta de micrófono no se movió en esta pasada: su setup/stop sigue siendo el
camino legacy MainActor porque el gate físico está bloqueado por TCC. Su
cleanup explícito existente se conservó y no se presenta como evidencia de la
nueva frontera CATap.

## Cancellation

Cancelar A desde el control plane:

1. invalida inmediatamente `activeAttempt`, `CaptureAttemptGate` y la
   `SessionGenerationGate` del modelo;
2. despierta el wait de primer frame y cancela el wait de `CaptureNativeWork`;
3. detiene la publicación de callbacks de A y deja la UI en estado cancelado;
4. encola el stop de A en el mismo owner serial.

La llamada nativa no se declara cancelada. Si `AudioCaptureSession.start()` aún
está dentro de CoreAudio, puede continuar hasta retornar. Al retornar, el work
observa stale/cancelación, destruye la sesión creada y no publica recording.

También se agregó un gate inmediatamente después de `liveStore.reset()` y
antes de encolar native start. Eso evita que una cancelación ocurrida durante
ese await encole setup A después del stop que ya había sido solicitado.

Mientras el cleanup nativo de A sigue pendiente, `isBusy` permanece verdadero;
B no comparte ni solapa el tap de A. B puede continuar sólo después de que el
work de A se complete y la cola serial haya ejecutado su stop.

## Stop

El stop separa explícitamente dos momentos:

- solicitud de stop: MainActor invalida generación, cierra el callback gate,
  marca `isCapturing = false`, detiene el pump y deja `CapturePhase.stopping`;
- teardown completado: `CaptureController.stop()` espera
  `CaptureNativeWork.waitForCompletion()`. Sólo después de que la cola retorne
  se continúa con mic legacy, wrapping/validación WAV y se publica
  `CapturePhase.idle`.

El wait es async y no congela MainActor. El work de stop es idempotente por
attempt: retira la sesión del diccionario una sola vez y llama `stop()` sólo al
recurso que posee. El watcher de completitud sólo limpia handles de control
cuando la operación realmente terminó.

## Generation safety

Los callbacks pasan por un `CaptureAttemptGate` thread-safe antes de entrar al
`AsyncStream`; un callback de A después de invalidar A no llega al buffer de B.
Todos los saltos de vuelta a MainActor posteriores al native wait comprueban el
attempt antes de publicar audio, estado, nivel o error. El catch stale del
modelo tampoco escribe el error de A sobre el estado de B.

El test `AToBGenerationOwnership` fuerza el orden:

`A setup → cancel/invalidate A → A resource destroyed → B setup → B published`.

La cola serial retrasa B detrás del cleanup de A por diseño. No se inventa
concurrencia entre taps.

## Fault injection

Se agregaron en
`app/MeetingTranscriber/ClassScribeTests/CaptureNativeExecutionTests.swift`
los siete tests solicitados:

1. `nativeStartRunsOffMainActor`
2. `cancelReturnsWhileNativeStartStillBlocked`
3. `cancelledAttemptCannotPublishAfterNativeReturn`
4. `staleAResourceIsCleaned`
5. `slowNativeStopDoesNotBlockMainActor`
6. `teardownCompletionIsNotReportedEarly`
7. `AToBGenerationOwnership`

El seam usa una operación bloqueada en la cola nativa y señales async en el
test; el test no bloquea MainActor para esperar la entrada. El harness temporal
compilado contra el `CaptureNativeExecution.swift` actual ejecutó:

`native-boundary-harness=PASS tests=7`

Evidencia adicional:

- MainActor/control plane permanece schedulable mientras la operación nativa
  simulada espera un semaphore;
- cancelar devuelve el wait de A sin liberar artificialmente la llamada nativa;
- A no publica después de volver y marca cleanup;
- la completitud de teardown no se anuncia antes de liberar la operación;
- B no entra hasta que el owner serial termina A.

La suite Swift Testing del target de producto no pudo ejecutarse en este host:
el active developer directory es sólo Command Line Tools y no hay módulo
`Testing`/runtime XCTest disponible. El parse y el harness de runtime sí
pasaron; no se declara una ejecución XCTest/Swift Testing PASS.

El typecheck Swift 6 `-strict-concurrency=complete` de todas las fuentes
activas del producto, usando los módulos locales disponibles, pasó; también
pasó el typecheck estricto de todas las fuentes de AudioTapLib. `swift build`
no pudo planificar el paquete porque el manifest local usa
`swiftLanguageModes: [.v6]`, API no disponible en el PackageDescription del
active Command Line Tools.

## Physical CATap regression

Se repitió el gate mínimo con audio sintético local (`/usr/bin/say` +
`/usr/bin/afplay`) y un probe temporal construido contra el
`CaptureNativeExecutor` actual, `AudioCaptureSession` y los objetos CATap de
AudioTapLib. La secuencia incluyó producing, stop inmediato y dos ciclos A→B.
El contador se midió antes de stop y 500 ms después del retorno del teardown.

| Attempt | Registro (s) | Setup (s) | Primer frame (s) | Stop + teardown (s) | Callbacks antes/después 500 ms | Raw bytes | Resultado |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| A producing | 0.085589 | 0.031371 | 0.200766 | 0.008671 | 35/35 | 23896 | PASS |
| immediate stop | 0.113627 | 0.025406 | — | 0.016096 | 0/0 | 0 | PASS |
| A→B, A | 0.120886 | 0.026937 | 0.052684 | 0.011911 | 45/45 | 31404 | PASS |
| A→B, B | 0.122085 | 0.025034 | 0.050846 | 0.010688 | 47/47 | 32768 | PASS |

La prueba confirma la frontera física focalizada: producción, stop inmediato,
reutilización A→B y ausencia de callbacks posteriores. El probe no es el
runtime completo de `CaptureController`/SwiftUI; ese target no pudo construirse
con el active developer directory actual. Por ello estos resultados son un
PASS del executor/CATap subsystem gate, no un claim de la matriz completa de
producto ni de micrófono.

La evidencia previa del camino normal también mostró setup aproximado de
29–36 ms, primer frame de 62–207 ms y stop/teardown de 4–20 ms. Los nuevos
resultados permanecen en el mismo orden de magnitud.

## Process isolation decision

**INCONCLUSIVE — PHYSICAL FAULT GATE PENDING**

La evidencia disponible no soporta `PROCESS ISOLATION REQUIRED`: el camino
físico normal CATap es bounded y el control plane ahora permanece responsive.
Tampoco permite cerrar `IN-PROCESS ACCEPTABLE`: el fault injection demuestra
que una llamada nativa síncrona no cooperativa puede ocupar la cola serial y
retrasar B aunque no congele MainActor. No se observó esa llamada material en
el gate físico normal y no se implementó helper de proceso.

La decisión queda evidence-gated hasta disponer de un fault gate físico o
reproducible de una llamada CoreAudio material que impida cancel/stop/next
attempt de forma no bounded.

## Gates pendientes

- **Micrófono:** `SKIPPED — TCC`; el host permanece en autorización
  `.notDetermined`; no se solicitó permiso ni se capturó audio personal.
- **Windows:** `SKIPPED — PHYSICAL WINDOWS / dotnet unavailable`; no se instaló
  runtime ni se declara PASS físico.
- **Suite de producto:** `SKIPPED — Xcode/Testing runtime unavailable`;
  `xcodebuild` existe pero el active developer directory apunta a Command Line
  Tools y `xctest` no está disponible.
- **Process isolation:** fault gate físico/reproducible de llamada nativa no
  cooperativa pendiente.
- **Plan:** el checkbox “Caracterizar físicamente si setup/teardown de captura
  requiere aislamiento de proceso” permanece abierto; Fase 1 no se declara
  completa.

No se ejecutaron GitHub Actions, push, PR, tags ni releases.
