# Caracterización Fase 2D — master fiel y derivado ASR

Fecha: 2026-08-25

Estado: **COMPLETE / PARTIAL**. La separación entre el master durable de
application/systemOutput y el derivado ASR 16 kHz mono está implementada en el
target macOS activo, en el paquete AudioTap y en el product path Windows. Hay
build de producto macOS y contratos deterministas disponibles; XCTest
standalone no está disponible en este host y `dotnet`/`csc` tampoco. Los gates
runtime/physical que requieren esos entornos o audio real permanecen
**SKIPPED/PENDING**, no PASS.

La Fase 2 completa sigue abierta. Fase 2C.1 y Fase 2C.2 permanecen
**APPROVED** según sus caracterizaciones; Fase 2E y Fase 2F siguen
**NOT STARTED**. Esta fase no afirma release readiness completo.

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
downmixea entradas de más de dos canales y convierte el sample rate sólo cuando
la fuente cambia. La generación y los leases existentes siguen filtrando
callbacks tardíos. El stop drena la captura, cierra/flush del master, valida el
manifest, deriva `source.wav` y continúa el pipeline actual. La ruta de
micrófono conserva el camino legacy de esta fase; no se afirma fidelidad
master source-rate para micrófono.

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
descriptor inmutable del master y lo escribe en `master.raw`. En paralelo,
convierte a 16 kHz mono para el snapshot ASR reciente. Los contadores de
duración durable y de ASR son independientes. El stop conserva el ownership
single-flight existente, deriva `source.wav` una vez desde el master y deja el
master/manifest disponibles para recovery si la derivación falla.

Se escribieron pruebas del product path para formato real del recorder,
elección por primer PCM no vacío, cambio de formato en rebind, timeline/gap,
single-flight, derivación, recovery y compatibilidad legacy. El compile/runtime
Windows queda **SKIPPED — dotnet/csc unavailable**; no se instaló SDK.

## Timeline, rebind y duración

La línea durable usa frames, bytes por frame y sample rate del master. Un
callback vacío o stale no fija el formato. Durante un rebind se drena la
generación vieja, se avanza la generación, se reutiliza el mismo descriptor y
archivo de master, y un nuevo formato de entrada se convierte antes de
escribir. El evento queda registrado en `conversions` del manifest.

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
| `./scripts/pre-push.sh --with-tests` | **PASS**; bundle macOS, compilación de tests y 239 tests pasaron |
| `swift build --package-path tools/audiotap -c release -j 2` con el `.toolchain` local y `-strict-concurrency=complete` | **PASS** |
| `swift test --package-path tools/audiotap -j 2` con el `.toolchain` local, `-resource-dir` y `-strict-concurrency=complete` | **SKIPPED — XCTest unavailable**; Command Line Tools devuelve `no such module 'XCTest'` |
| Product path Windows y contratos equivalentes | código y tests escritos; revisión estática disponible; runtime **SKIPPED — dotnet/csc unavailable** |
| `git diff --check` | **PASS** |

La suite standalone de AudioTap no se presenta como PASS porque el host no
expone XCTest utilizable. La suite de producto macOS sí pasó mediante
`pre-push`; tampoco se presenta la suite Windows como compilada o ejecutada.
No se inventan conteos de tests.

## Gates físicos y trabajo diferido

No se ejecutó un gate de fidelidad física CATap con output audible real,
exclusión de ClassScribe, cambio de dispositivo y teardown; queda
**PENDING / SKIPPED**. El gate TCC queda **PENDING**. Los gates físicos de
Windows, cambio de hardware/device y runtime Windows quedan
**PENDING / SKIPPED — dotnet/csc unavailable**. Las pruebas sintéticas y los
builds locales no convierten esos estados en PASS.

Fase 2E decidirá el formato para clases largas mediante fixture real. RF64,
W64 y segmentación siguen fuera de alcance; `master.raw` no impone ahora un
límite RIFF y `source.wav` sólo se materializa con límites seguros. No se
inicia Fase 2E, Fase 2F ni Fase 3.
