# Correctivo post-v0.9.0 — concurrencia, VAD fail-open y diagnostics

Estado: **ACTIVA / CORRECTIVO FOCALIZADO**

Esta SPEC no asigna una versión de release. Complementa a
[`v0.8.0.md`](v0.8.0.md) (contrato base escrito; la release actual es
v0.9.0) para cerrar problemas confirmados después de la
investigación de performance; no redefine la frontera de release.

## Objetivo

Cerrar dos fallos de correctness que pueden perder o publicar estado sobre la
sesión equivocada, acotar el fallback opcional de VAD para que nunca bloquee
indefinidamente el pipeline principal, corregir literales visibles en caminos
activos, dejar diagnostics opt-in suficientes para medir P0 y aplicar una
optimización focalizada en macOS: eliminar la dependencia serial final
ASR → diarización mediante structured concurrency, con speaker attribution
posterior a ambas ramas. La mejora está inferida por la eliminación de esa
dependencia; no hay benchmarks físicos.

## Scope

- Windows: `ApplySpeakerCorrectionAsync`, serialización del scope de
  correcciones, fallback VAD con presupuesto finito y diagnostics de
  finalización.
- macOS: fallback VAD con presupuesto finito, literales activos, diagnostics
  de finalización, concurrencia estructurada de ASR final + diarización con
  audio cerrado, speaker attribution posterior a ambos resultados y
  persistencia temprana del transcript ASR en estado `diarizing`.
- Tests focales para aislamiento A→B, ordering de correcciones y fallos
  materiales del fallback que puedan probarse sin hardware.
- Instrucciones reproducibles para ejecutar las aplicaciones reales con
  `CLASSSCRIBE_PERF_DIAGNOSTICS=1`.

## Out of scope

No incluye cambiar proveedor/modelo ASR, cambiar el formato de
persistencia, prewarm, circuit breaker general, `Sources/` o `Tests/`
legacy, cleanup general, release, merge o versión nueva. La semántica de
full retranscription por gaps se conserva.

## Arquitectura y critical paths relevantes

- Windows finaliza desde `MainViewModel.ProcessWaveAsync`; ASR final y
  diarización pueden solaparse y las proyecciones se escriben mediante
  `SessionStore`.
- Windows aplica correcciones desde `ApplySpeakerCorrectionAsync`, que debe
  capturar identidad, destino e inputs antes de esperar y publicar sólo si la
  identidad visible sigue vigente.
- Windows `WhisperTranscriber` y macOS `ParakeetService` usan VAD como
  optimización/aceptación opcional; si VAD falla o agota su presupuesto, el
  ASR existente continúa por su fallback fail-open.
- macOS finaliza en `ClassScribeModel.runFinalProcessing`; la instrumentación
  debe conservar timestamps monotónicos que permitan distinguir ASR final,
  VAD, diarización, atribución, post-procesamiento, persistencia y UI-ready.
- Windows conserva overlap ASR/diarización con semántica
  checkpoint/tail/full intacta.
- macOS elimina la dependencia serial ASR→diarización mediante structured
  concurrency (`async let` para ASR final y diarización con el audio ya
  cerrado); speaker attribution espera ambos resultados y el transcript ASR
  se persiste (estado `diarizing`, nunca `complete`) antes de esperar
  speakers, para conservar la recuperación ante fallo de diarización.
- La mejora de latencia macOS está inferida por eliminación de la
  dependencia serial demostrada; no hay benchmarks cold/warm ni medición
  física de runtime.

## Invariants

1. Una corrección iniciada para A sólo persiste contra A; nunca publica estado
   visual en B. La selección de profesor y el guardado de ediciones capturan
   identidad (attempt, carpeta) antes de esperar el gate y son no-op si la
   sesión visible ya no es la solicitada.
2. Dos correcciones rápidas de una misma sesión tienen ordering determinista y
   ninguna lectura-modificación-escritura pierde la operación anterior.
3. El snapshot autoritativo de attempt, sesión, carpeta, target y overlay se
   toma antes del primer `await`; cada `await` relevante revalida autoridad.
4. Cada llamada pública de análisis VAD tiene UN presupuesto TOTAL máximo de
   15 segundos compartido entre sus etapas; el reloj no se reinicia entre
   resample, load e inferencia. Download/load/init/timeout/error de VAD no
   bloquean indefinidamente ASR ni grabación, no crean loops de retry y
   preservan la cancelación del caller.
5. Los diagnostics son opt-in, monotónicos, locales y no contienen audio,
   transcript, paths ni otros datos sensibles innecesarios.
6. Audio, transcript ASR original, metadata y correcciones humanas históricas
   permanecen preservados.

## Problemas confirmados

- `ApplySpeakerCorrectionAsync` lee estado mutable antes y después de `await`;
  dos operaciones concurrentes también pueden perder updates al hacer
  read-modify-write del overlay.
- El VAD existente sólo tiene fallback por excepción; la carga/descarga/init
  no posee un deadline de producto y Windows configura HTTP sin timeout.
- Hay literales visibles hardcodeados en live/retry y caminos equivalentes.
- Los diagnostics iniciales aún deben registrar explícitamente cobertura,
  motivo de invalidación, tail reutilizado y solapamiento Windows, además de
  dejar visible la concurrencia ASR/diarización de macOS.

## Acceptance criteria

- Tests deterministas demuestran que A se guarda en A aunque se abra B antes
  de liberar la persistencia, y que dos correcciones cercanas conservan el
  ordering seleccionado.
- Windows y macOS tienen presupuesto finito para VAD/provisioning; timeout,
  error o cancelación interna dejan VAD no disponible para ese contexto y
  continúan por ASR sin retry loop.
- Los caminos visibles activos usan las claves de localización existentes o
  nuevas claves mínimas con traducciones para los locales soportados.
- Diagnostics off no ejecuta trabajo relevante; diagnostics on registra todos
  los hitos P0 solicitados sin contenido sensible.
- La semántica de full retranscription por gap no cambia; Windows conserva
  overlap ASR/diarización y macOS conserva atribución posterior a ambos
  con persistencia temprana ASR sin marcar la sesión como completa.

## Estrategia de validación

Aplicar `focused → subsystem`: tests focales de proyección/concurrencia y VAD,
parse/build/test disponibles por plataforma, `git diff --check`, inspección
del diff contra esta SPEC y revisión explícita de fallbacks, catches,
assertions y tests. Los gates físicos de TCC/audio/hardware/Windows no se
presentan como ejecutados en este entorno.

## Cleanup ejecutado (2026-09-21)

Cleanup mínimo sin cambio de comportamiento: se eliminó la
infraestructura ASR sin consumidores (`AsrWorkerProtocol`,
`AsrWorkerProcessTransport`, `AsrWorkerSupervisor`,
`AsrWorkerProcessLifecycle`, fakes y sus tests/fixtures exclusivos en
ambas plataformas), el campo `loadedModelPath` (sólo escrituras),
`CLAUDE.md`/`CONTRIBUTING.md` (arquitectura upstream contradictoria),
`docs/architecture-macos.md`/`docs/automation-api.md` (RPC/arquitectura
fuera del target ClassScribe) y los scripts
`configure-tag-ruleset.sh` (config inexistente, repo upstream) y
`generate_social_preview.py` (branding upstream). Se corrigieron
`README.md`/`docs/WINDOWS.md` (modelo real `ggml-small-q5_1.bin`
~181 MB) y `docs/DISTRIBUTION.md` (repositorio público verificado).
Se conservan `Sources/`/`Tests/` upstream, `site/`, `Casks/`,
`tools/mt-cli`, `tools/meeting-simulator`, E2E legacy, `docs/plans/`,
`FINALIZATION_PLAN.md`, licencias y `ProcessingIPC` (diarización en
uso) como follow-ups o requisitos legales; `downloadProgress`
write-only de `Inference.swift` queda diferido por firma externa sin
compilador disponible. Los elementos diferidos están resumidos en la
sección "Follow-ups diferidos" de [`PLAN.md`](../../PLAN.md); la historia
detallada vive en `docs/specs/v0.8.0.md`, `docs/characterization/` y el
historial Git cuando corresponda.
