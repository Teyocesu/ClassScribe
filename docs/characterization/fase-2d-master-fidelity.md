# Caracterización Fase 2D — master fiel y derivado ASR

Fecha: 2026-08-26

Estado: **APPROVED arquitectónicamente y con toda la evidencia local disponible**.
La separación entre el master durable de application/systemOutput y el derivado
ASR 16 kHz mono está implementada en el target macOS activo, en el paquete
AudioTap y en el product path Windows. Esta corrección añade resampling master
streaming stateful, handoff determinista y propagación terminal de fallos
durables; Windows usa una política explícita de formato observable para
process-loopback. Hay build de producto macOS y contratos deterministas
disponibles. XCTest standalone no está disponible en este host y `dotnet`/`csc`
tampoco. Los gates runtime/physical que requieren esos entornos o audio real
permanecen **SKIPPED/PENDING**, no PASS.

La aprobación de 2D es arquitectónica/local y no afirma multiplatform release
readiness. Fase 2C.1 y Fase 2C.2 permanecen **APPROVED** según sus
caracterizaciones. Fase 2E queda **DIFERIDA / NOT STARTED**.

## Contrato de artefactos

Para nuevas sesiones online (`application` o `systemOutput`) la fuente de
verdad durable es:

```text
master.raw
audio-manifest.json
```

`source.wav` es un derivado materializado para ASR/diarización. El master no
se elimina después de generar el derivado ni cuando la derivación falla.
`source.raw` conserva exclusivamente la semántica legacy de sesiones
anteriores; una sesión histórica sigue recuperándose por el camino legacy si
no tiene un manifest válido.

El master usa PCM Float32 little-endian interleaved. Su sample rate es el de
la primera fuente PCM no vacía aceptada para el `SessionAttemptID`; sus canales
son 1 o 2, y una entrada con más de dos canales se downmixea a stereo. No se
fija por conveniencia a 16 kHz mono y el descriptor queda inmutable durante el
intento.

`source.wav` se genera desde `master.raw` como 16 kHz mono: Float32 little-endian
en el target macOS y PCM16 little-endian en Windows, de acuerdo con el formato
que consume cada pipeline ASR. Es un plano separado del live sink/ring de ASR y
no reemplaza al master.

## Manifest

El manifest es versionado, estructurado y cross-platform-equivalent:

```json
{
  "version": 1,
  "master": {
    "relativePath": "master.raw",
    "encoding": "float32LE",
    "sampleRate": 48000,
    "channels": 2
  },
  "asrDerivative": {
    "relativePath": "source.wav",
    "encoding": "float32LE",
    "sampleRate": 16000,
    "channels": 1
  },
  "conversions": [
    {
      "sourceGeneration": 2,
      "inputSampleRate": 44100,
      "inputChannels": 2,
      "outputSampleRate": 48000,
      "outputChannels": 2
    }
  ]
}
```

El ejemplo muestra el manifest macOS; el mismo campo vale `pcm_s16le` en el
target Windows.

Los paths se validan como relativos, permanecen dentro de la carpeta de la
sesión y se restringen a los nombres contractuales. No se guarda audio en
JSON. El manifest se escribe atómicamente antes del primer byte del master;
los permisos del archivo son owner-only en macOS (`0600`). Windows usa la
carpeta privada de sesión bajo `LocalApplicationData` y su ACL heredada; la
confirmación en un runtime Windows queda pendiente.

## macOS — master y ASR live

El target activo es `app/MeetingTranscriber/ClassScribeSources`. Para una
captura online, `AudioCaptureSession` crea el writer del master y conserva la
misma sesión/archivo durante los rebinds. `AppAudioCapture` bifurca cada
buffer nativo: el writer normaliza el formato real a master Float32
source-rate/stereo, mientras el resampler existente alimenta el sink live a
16 kHz mono. El live sink es cache para ASR, no la fuente de verdad durable.

El writer acepta la primera entrada no vacía, mantiene el descriptor de master,
downmixea entradas de más de dos canales y convierte el sample rate mediante un
`StreamingMasterResampler` stateful. El `MasterFrameClock` pertenece al
`SessionAttemptID` completo: acumula la duración exacta de cada fuente en frames
master y redondea sólo el total acumulado, conservando el remainder entre
generations y cambios de formato. Cada converter conserva su phase/interpolación
local y se drena antes de resetearse; no comparte muestras ni interpola a través
del silencio del handoff. La ruta de sample-rate idéntico usa un fast path que
normaliza canales pero entrega todos los frames sin lookahead temporal.

La `TimelineAnchor` usa cobertura lógica asignada por el clock, no el número de
frames físicamente emitidos en ese callback. Así, el lookahead de un converter no
se convierte en un cero sintético; un salto real del host time sigue insertando
silencio. El tail de `finish()` sólo completa el presupuesto ya reservado y no
avanza la línea temporal por segunda vez. La generación y los leases existentes
siguen filtrando callbacks tardíos. La ruta de micrófono conserva el camino
legacy de esta fase; no se afirma fidelidad master source-rate para micrófono.

Un fallo de escritura del master es terminal y recoverable: gana el primer
error, bloquea nuevas escrituras y conserva el `master.raw`/manifest válido ya
existente. Se transporta como `CaptureNativeTerminalFailure` tipado (`source` o
`durableMaster`) desde `MasterAudioWriter`/fuente, a través de
`AudioCaptureSession` y `CaptureNativeExecutor`, hasta `CaptureController`.
El control plane no puede informar éxito de finalización simplemente porque un
master parcial permita derivar `source.wav`. El live ASR puede conservar datos
transitorios, pero no oculta el fallo de la fuente durable. Un nuevo
`SessionAttemptID` recibe estado limpio.

Sólo un fallo de la fuente de una aplicación puede ofrecer la sugerencia
explícita `.systemOutput`. Un fallo `durableMaster`, de almacenamiento o de
finalización nunca ofrece esa sugerencia; tampoco la ofrece un fallo durable de
`systemOutput`. No hay fallback automático ni hot-switch.

La recuperación de una sesión nueva intenta primero `master.raw` + manifest
válido y regenera `source.wav` si falta o es inválido. Si ese par no es válido,
se conserva la recuperación histórica desde `source.raw`; no se reinterpreta
un raw legacy como Float32 master.

## Windows — master y ASR live

El target es `app/ClassScribe.Windows`. `IWindowsAudioRecorder` expone un
`AudioPcmFormat` tipado con sample rate, canales, representación y bytes por
frame. Para `application` y `systemOutput`, la fábrica conserva el formato
efectivo entregado por NAudio/WASAPI (`WaveFormat`/`AsStandardWaveFormat()`);
no fuerza 16 kHz mono al recorder durable. El micrófono puede seguir usando el
formato legacy fijo.

El callback con attempt y generation válidos convierte el PCM nativo al
descriptor inmutable del master y lo escribe en `master.raw` mediante un
resampler streaming stateful. En paralelo, convierte a 16 kHz mono para el
snapshot ASR reciente. Los contadores de duración durable y de ASR son
independientes; `MasterFrameClock` mantiene el presupuesto entre generations y
`CaptureHandoffTimeline` recibe la cobertura lógica aunque el paquete físico sea
vacío por lookahead. El tail drenado completa el presupuesto existente y no se
vuelve a sumar a la timeline. El stop conserva el ownership single-flight
existente, deriva `source.wav` una vez desde el master y deja el master/manifest
disponibles para recovery si la derivación falla. Si la escritura authoritative
del master o la finalización/storage falla, `StopAsync` lanza un
`CaptureTerminalException` tipado después de drenar recursos: la derivación
parcial puede conservarse, pero nunca convierte la sesión en success. El
`MainViewModel` marca el intento como `Recoverable`, no ejecuta el procesamiento
final y no ofrece `SystemOutput`. Un fallo `Source` sigue pudiendo finalizar el
audio durable validado; el timeout explícito de handoff mayor a 30 s se clasifica
como `Source`, no como `DurableMaster`.

Para process-loopback, Windows consulta el mix del default render endpoint
observable por ClassScribe y solicita explícitamente ese formato con
`WithFormat(...)`; conserva mono y limita más de dos canales a stereo. NAudio
no ofrece aquí un `GetMixFormat` por proceso, así que esto no se presenta como
sample rate nativo individual de la aplicación: si Windows enruta la app a otro
endpoint, la limitación queda explícita. `SystemOutput` mantiene el formato
real del render endpoint.

Se escribieron pruebas del product path para formato real del recorder,
elección por primer PCM no vacío, cambio de formato en rebind, timeline/gap,
single-flight, derivación, recovery, compatibilidad legacy y el presupuesto
global de frames entre generations/formats. La cobertura exacta del correctivo
incluye `durableMasterFailureCannotFinalizeAsSuccess`,
`durableMasterFailureDoesNotRunFinalProcessing`,
`sourceFailureCanStillFinalizeValidatedPartialAudio`,
`handoffTimeoutIsSourceFailure`,
`durableFailureDoesNotRecommendSystemOutputWindows`,
`newAttemptDoesNotInheritDurableFailureWindows` y
`stopFollowersObserveSameDurableFailure`; también se cubre la falla de
finalización/storage. El compile/runtime Windows queda **SKIPPED —
dotnet/csc unavailable**; no se instaló SDK.

Los contratos deterministas cubren 44.1 kHz → 48 kHz con 10.000 callbacks de
256 frames, 48 kHz → 44.1 kHz con callbacks de 127 frames, tamaños alternos
127/256/511, una rampa dividida frente a un bloque único, continuidad de
boundaries, presupuesto global en diez generations, cambios de formato,
lookahead sin cero sintético, gap real, tail idempotente y la cobertura lógica
usada por `CaptureHandoffTimeline`. También se verifica que la conversión del
manifest aparezca una sola vez por generation/format. Estos casos permanecen
sujetos a la disponibilidad de cada suite indicada en la tabla de evidencia.

## Timeline, rebind y duración

La línea durable usa frames, bytes por frame y sample rate del master. Un
callback vacío o stale no fija el formato. Durante un rebind se drena la
generación vieja, se avanza la generación, se reutiliza el mismo descriptor y
archivo de master, y un nuevo formato de entrada crea un converter independiente
antes de escribir. El frame clock no se reinicia: sólo el estado de interpolación
se reinicia. El tail drenado se registra físicamente antes de planear el gap
durable, pero su cobertura ya estaba reservada; no se interpola a través del
silencio y el evento queda registrado una sola vez en `conversions` del manifest
por generation/format.

Los gaps se insertan como silencio alineado al master y el derivado conserva la
misma duración temporal mediante resampling global. La duración online se
calcula desde los frames del master, no desde el tamaño del `source.wav` ni del
ring ASR. La conversión evita concatenar bytes de 48 kHz y 44.1 kHz con
semánticas incompatibles.

## Persistencia y recuperación

La metadata nueva conserva `schemaVersion` y añade sólo una referencia
opcional al manifest y el `formatVersion` del audio master. La identidad de
formato no depende de strings localizados. La lectura de metadata sin manifest
continúa por el camino legacy. Se conservan el audio original, el transcript
ASR original y los overlays de correcciones humanas existentes.

## Evidencia y validación local

Resultados reproducibles de este checkout:

| Validación | Resultado |
| --- | --- |
| `./scripts/run_app.sh --build-only` | **PASS**; bundle release macOS y codesign verificado |
| `./scripts/pre-push.sh --with-tests` | **PASS**; bundle macOS, compilación de tests y 251 tests pasaron |
| `swift build --package-path tools/audiotap -c release -j 2` con el `.toolchain` local y `-strict-concurrency=complete` | **PASS** |
| `swift test --package-path tools/audiotap -j 2` con el `.toolchain` local, `-resource-dir` y `-strict-concurrency=complete` | **SKIPPED — XCTest unavailable**; Command Line Tools devuelve `no such module 'XCTest'` |
| Product path Windows y contratos equivalentes | código y tests escritos; revisión estática disponible; runtime/compile **SKIPPED — dotnet/csc unavailable** |
| `git diff --check` | **PASS** |

La suite standalone de AudioTap no se presenta como PASS porque el host no
expone XCTest utilizable. La suite de producto macOS sí pasó mediante
`pre-push`, incluyendo el test product-path de fallo durable; tampoco se
presenta la suite Windows como compilada o ejecutada. No se inventan conteos de
tests.

## Gates físicos y trabajo diferido

No se ejecutó un gate de fidelidad física CATap con output audible real,
exclusión de ClassScribe, cambio de dispositivo y teardown; queda **PENDING**.
El gate TCC queda **PENDING**. Los gates físicos de Windows y cambio de
hardware/device quedan **PENDING**; el compile/runtime Windows queda
**SKIPPED — dotnet/csc unavailable**. Las pruebas sintéticas y los builds
locales no convierten esos estados en PASS.

Fase 2E queda diferida y no se inicia en este checkpoint. La decisión
provisional es que `master.raw` no impone un límite RIFF y `source.wav` sigue
siendo WAV dentro del contrato actual. No se elige RF64, W64 ni segmentación
sin un fixture de clase larga y evidencia de que una duración razonable queda
bloqueada; la truncación silenciosa está prohibida. Si ese gate falla, el
hallazgo vuelve a un correctivo focalizado antes de RC; de lo contrario, 2E
permanece posterior a v0.8.0.
