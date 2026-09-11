# Plan de ClassScribe v0.9.0

Fecha: 2026-08-26

Baseline canónico del release checkpoint #1: `9d80826f598b77dfd0646853501e6e5eafac0af6` en `v0.8.0-development`.

Estado canónico: Fase 1A **APPROVED**; Fase 1B **APPROVED arquitectónicamente**; Fase 1C **ARCHITECTURE APPROVED**; Fase 2A **FIXED / PARTIAL**; Fase 2B.1 **COMPLETE / PARTIAL**; Fase 2B.2 **PASS en Windows**; Fase 2C.1 y Fase 2C.2 **PASS en Windows**; Fase 2D **PASS en Windows para el contrato validado**. Windows W0/W1A/W1B tienen evidencia de runtime y física **PASS**. Permanecen pendientes los gates físicos de macOS, TCC, hardware/device-change y los acceptance gates compartidos indicados abajo. Fase 2E queda **DIFERIDA / NOT STARTED**.
SPEC canónica: [`docs/specs/v0.8.0.md`](docs/specs/v0.8.0.md)

## Estado actual v0.9.0

v0.8.0 está publicada sobre su frontera estable. El trabajo actual de v0.9.0
implementa ASR confiable con gate de voz, aceptación de hipótesis, backoff
finito, prewarm fuera de captura/UI y backlog live acotado, preservando el
audio durable y las correcciones humanas.

SPEC de v0.9.0: [`docs/specs/v0.9.0.md`](docs/specs/v0.9.0.md)

Este documento es mutable: ordena trabajo pequeño y verificable. No redefine requisitos. Cada fase se valida localmente con el patrón `focused → subsystem`; los gates con TCC, hardware, llamada real o Windows físico están definidos en la SPEC. La frontera estable y la política de release están fijadas por el bloque `RELEASE CHECKPOINT v0.8.0`.

## Fase 0 — Baseline y contrato

Estado: **completada en esta sesión, sólo documentación**

- [x] Inventariar targets activos y documentación existente.
- [x] Recuperar el informe previo de startup y contrastar cada hallazgo con el `HEAD` actual.
- [x] Auditar macOS/Windows: captura, ASR/idioma, diarización, persistencia y localización.
- [x] Investigar APIs nativas y capacidades de FluidAudio, Whisper y sherpa-onnx.
- [x] Crear una SPEC canónica y reglas permanentes mínimas del repo.

Salida: SPEC, PLAN y `AGENTS.md`. No se modificó código de producto.

## Fase 1 — Estado, schema y supervisión

Estado: **APPROVED** en arquitectura y gates locales disponibles. Los gates físicos de release macOS/TCC/hardware permanecen pendientes.

Objetivo: crear las fronteras que permiten implementar features sin estados falsos ni datos destructivos.

- [x] Introducir IDs de intento/generation y ejes `CapturePhase`, `AsrPhase`, `SessionPhase` sin strings localizadas persistidas.
- [x] Definir schema v2 aditivo y golden fixtures de sesiones macOS/Windows v0.7.
- [x] Separar transcript ASR original, propuestas de diarización y overlay de correcciones.
- [x] Prototipar protocolo versionado y supervisor del worker ASR en ambas plataformas (serialización y terminalización exactly-once; arquitectura aprobada, runtime Windows validado en W0).
- [x] Probar cancel, crash, heartbeat, deadline y callback tardío con worker falso y transporte process-backed macOS; macOS runtime **PASS**, Windows runtime W0 **PASS**.
- [ ] Caracterizar físicamente si setup/teardown de captura requiere aislamiento de proceso.

Exit gate: cancelación determinista por fase, una sesión legacy abre sin reescritura y un worker colgado no bloquea stop ni el intento siguiente.

Progreso aprobado arquitectónicamente de Fase 1B: se añadieron envelopes versionados, negociación explícita,
supervisores con una frontera serializada por plataforma, transporte process-backed y fake
workers deterministas para macOS y Windows. El helper real macOS cubre éxito, crash, malformed
frame, EOF, heartbeat/deadline, cancelación ignorada y A→B con muerte del proceso. El typecheck
focalizado y el runtime process-backed macOS pasan; el runtime Windows process-backed quedó
validado con el SDK canónico en W0. El lifecycle Windows de setup/exit quedó protegido contra la
carrera de inicialización, con tests deterministas de exit-wins, terminate-wins y setup normal.

Progreso aprobado de arquitectura de Fase 1C: la ruta real macOS de aplicación mediante CATap/AudioTapLib
se ejecutó con audio sintético local a través del nuevo `CaptureNativeExecutor`; setup, primer frame,
stop/teardown, ausencia de callbacks posteriores, stop inmediato y dos ciclos A→B retornaron dentro
de los tiempos medidos. El control plane quedó desacoplado del setup/stop síncrono y cada native work
lleva `SessionAttemptID`; una segunda operación espera cleanup A en la cola serial, sin solapar taps.
El subsystem físico CATap macOS es **PASS**. La fault injection determinista mostró que cancelación/control
plane siguen respondiendo mientras una llamada no cooperativa ocupa el owner, pero B necesariamente
espera su retorno; process isolation queda **INCONCLUSIVE / evidence-gated** y no es requerida por la
evidencia actual. El micrófono queda physical gate pending — `SKIPPED — TCC` porque el host local está
en `.notDetermined`; los gates Windows de runtime, application loopback, system output,
rebind y endpoint change quedaron validados en W0/W1A/W1B. Hardware/device-change continúa
pendiente. El detalle reproducible existente está en
[`docs/characterization/fase-1c-capture.md`](docs/characterization/fase-1c-capture.md).

## Fase 2 — Captura confiable y audio del equipo

Estado: **FASE 2D PASS en Windows para el contrato validado**: master durable source-rate/stereo separado del derivado ASR 16 kHz mono, con resampling streaming stateful, handoff drenado sin interpolar a través del gap, fallo durable terminal observable y política explícita de formato process-loopback. Windows W0/W1A/W1B validaron restore/build/test, publish, runtime, captura física, endpoint y recovery. Permanecen pendientes el gate físico CATap global macOS, TCC, hardware/device-change y los acceptance gates compartidos; estos estados no equivalen todavía a release readiness. Fase 2C.1 y Fase 2C.2 quedan **PASS en Windows**; Fase 2A permanece **FIXED / PARTIAL**, Fase 2B.1 permanece **COMPLETE / PARTIAL** y Fase 2B.2 queda **PASS en Windows**. Fase 2E queda **DIFERIDA / NOT STARTED**.

Objetivo: diferenciar transporte/señal y agregar global con consentimiento explícito y master fiel.

- [x] Fase 2A: clasificar `awaitingCallbacks`/`noCallbacks`/`silent`/`audible` con reloj monotónico inyectable y fixtures deterministas; voz/VAD queda diferida a Fase 3.
- [x] Fase 2A: integrar salud de callbacks en la ruta activa macOS y en la llegada de paquetes WASAPI de Windows, conservando ownership por `SessionAttemptID`.
- [x] Fase 2A: conservar callbacks silenciosos y callbacks vacíos como evidencia de transporte vivo; un stall es distinto de silencio y ASR permanece en un eje separado.
- [x] Fase 2A: ejecutar runtime/tests Windows; **PASS** en W0/W1A/W1B. `NoCallbacks`/silencio no sustituyen la liveness de identidad; la pérdida persistente tiene frontera `Source` separada.
- [x] Fase 2B.1: separar identidad lógica de encarnación PID y reconciliar aplicación/topología durante startup; validar AudioObjectIDs justo antes del handoff CATap y revalidar el root Windows antes de `BuildAsync`.
- [x] Fase 2B.2 **FIXED / PARTIAL**: macOS rebind durante grabación con confirmación → stop/drain de la generación vieja → avance de generación → salud fresca → build/start, recuperación post-stop explícita y seams de lifecycle; el gate físico PID lifecycle permanece pendiente.
- [x] Fase 2B.2 **PASS en Windows**: rebind durante grabación con drenaje de callbacks antes del cambio, timeline durable anclado al primer PCM no vacío inicial o post-handoff, gap total máximo de 30 s y reconstrucción por root reemplazado. Missing, Ambiguous y weak identity permanecen unresolved; no se selecciona sibling inseguro. La pérdida persistente supera el budget y publica `Source` exactamente una vez; el rebind verificado dentro del budget conserva la sesión.
- [x] Fase 2C.1 **PASS en Windows**: infraestructura CATap global y WASAPI render loopback con exclusión/self, autorización efímera por intento, generaciones, ownership durable, lifecycle serializado, Stop single-flight real hasta `FinalizeRaw`, cleanup post-`BuildAsync` y failure terminal observable; W0/W1A/W1B cubren compile/runtime, system output, endpoint change y shutdown.
- [x] Fase 2C.2 **PASS en Windows**: elección online aplicación/audio del equipo, modal de privacidad por intento, capability efímero ligado al intento y CTA `Capturar audio del equipo`; correctivo de ownership de presentación macOS **APPROVED**, separado del pending domain request; sin transición automática ni hot-switch. W1A/W1B validan cancel/accept, CTA y consentimiento nuevo.
- [x] Fase 2D **PASS en Windows para el contrato validado**: separar master source-rate/stereo durable (`master.raw` + manifest) del derivado ASR 16 kHz mono (`source.wav`); mantener un `MasterFrameClock` por `SessionAttemptID` con remainder global entre generations/formats, resetear sólo el estado de interpolación, evitar silencio sintético por lookahead y drenar/flushear cada converter exactamente una vez; transportar fallos terminales tipados (`source`/`durableMaster`) con recovery suggestion sólo para pérdida de una aplicación; en Windows, `DurableMaster`/`Storage` domina `StopAsync` como fallo recoverable aunque `source.wav` sea derivable, sin `ProcessWaveAsync`, y el timeout de handoff >30 s queda como `Source`; conservar la política explícita observable de formato process-loopback Windows. W0/W1A/W1B validan formato, persistencia, Stop, recovery y estabilidad post-teardown. La fault injection física destructiva de durable/storage no se ejecutó.
- [ ] Fase 2E **DIFERIDA / NOT STARTED**: `master.raw` no está limitado por RIFF; `source.wav` sigue siendo WAV. No elegir RF64, W64 o segmentación sin fixture y evidencia de que el contrato actual bloquea una duración razonable; la truncación silenciosa está prohibida.

Exit gate: los tests prueban que global es inalcanzable sin consentimiento; fixtures/gates físicos demuestran señal, PID lifecycle, master fidelity y recuperación.

Caracterización de Fase 2A: [`docs/characterization/fase-2a-signal-health.md`](docs/characterization/fase-2a-signal-health.md). Caracterización de Fase 2B.1: [`docs/characterization/fase-2b1-application-identity.md`](docs/characterization/fase-2b1-application-identity.md). Caracterización de Fase 2B.2: [`docs/characterization/fase-2b2-midrecording-rebind.md`](docs/characterization/fase-2b2-midrecording-rebind.md). Caracterización de Fase 2C.1: [`docs/characterization/fase-2c1-system-output-backends.md`](docs/characterization/fase-2c1-system-output-backends.md). Caracterización de Fase 2C.2: [`docs/characterization/fase-2c2-system-output-consent.md`](docs/characterization/fase-2c2-system-output-consent.md). Caracterización de Fase 2D: [`docs/characterization/fase-2d-master-fidelity.md`](docs/characterization/fase-2d-master-fidelity.md). Los hallazgos de revisión de 2A permanecen corregidos; el rebind 2B.2, los gates de arquitectura 2C.1/2C.2 y el correctivo 2D de streaming master/ASR, fallo durable y formato process-loopback están implementados con evidencia local disponible. Windows W0/W1A/W1B están **PASS**; los pendientes restantes son macOS/TCC/hardware y los acceptance gates compartidos de legacy, clase larga y no truncación silenciosa.

## RELEASE CHECKPOINT v0.8.0

Estado: **RELEASE CHECKPOINT REBASELINED** sobre `9d80826f598b77dfd0646853501e6e5eafac0af6` en `v0.8.0-development`.

### Frontera funcional estable

v0.8.0 incluye, como una única frontera contractual:

- arquitectura, lifecycle, estado, schema, ownership, cancelación y
  supervisión de Fase 1;
- salud de señal de Fase 2A;
- identidad de aplicación y rebind de Fases 2B.1/2B.2;
- backends de captura de aplicación/system output y explicitud global de
  Fase 2C.1;
- consentimiento por intento y CTA explícita de Fase 2C.2;
- master durable fiel, manifest y derivado ASR de Fase 2D;
- semántica asociada de stop/recovery/fallo y compatibilidad legacy necesaria,
  preservando audio, transcript original y correcciones humanas.

La aprobación arquitectónica/local de 2D no equivale a multiplatform release
readiness. No forman parte del requisito estable nuevo VAD/aceptación ASR,
circuit breaker, prewarm o backlog de Fase 3; el overhaul completo de speakers
de Fase 4; ni la localización completa de Fase 5.

### Gates Windows ejecutados

- Windows W0: **PASS** — SDK canónico .NET 10.0.302, restore locked, build 0 warnings/0 errors, 194/194 tests, self-contained publish, PE/native y worker smoke.
- Windows W1A: **PASS** — application loopback, system output, consentimiento, micrófono, artefactos durable, estabilidad post-Stop y startup/shutdown reales.
- Windows W1B: **PASS** — rebind físico, continuidad de sesión/master, cambio de endpoint, finalización, source-liveness persistente, CTA y consentimiento nuevo sin autoswitch.

### Gates faltantes antes de RC/estable

macOS requiere build/tests locales, TCC de audio/micrófono, CATap real de
aplicación y global con self-exclusion, identidad/rebind real, system output
con consentimiento explícito, cambio de output device, rate/canales/duración
del master, `source.wav` válido, Stop/recovery y ausencia de callbacks. El
baseline local tiene build/tests **PASS**; TCC y los gates físicos permanecen
**PENDING**.

Windows W0/W1A/W1B ya están **PASS**: restore/build/test, lanzamiento real,
application loopback, reemplazo/rebind de root/helper, system output/render
endpoint, consentimiento, endpoint change, master/manifest/`source.wav`,
durable write/recovery, Stop single-flight y rechazo de start durante
finalización. No se presenta ningún gate Windows de esta frontera como pendiente.

Ambas plataformas requieren abrir/reprocesar legacy, demostrar que un fallo de
aplicación nunca autoswitcha a system output, que un fallo durable/storage
nunca sugiere system output, que system output siempre exige consentimiento
nuevo, que no hay truncación silenciosa y que un fixture de clase larga
representativa cabe en el contrato WAV actual. Esos acceptance gates compartidos
y los gates físicos macOS/TCC/hardware siguen **PENDING/SKIPPED**, nunca PASS por
inferencia.

### Nota de packaging

`VERSION` todavía contiene `0.7.0`. Antes de cortar RC, la identidad de package/release
debe reconciliarse con v0.8.0; no forma parte de este gate y no se modifica aquí.

### Política de release

- La arquitectura puede aprobarse mientras un gate físico esté pendiente; una
  release estable no.
- El RC sólo se corta después de ejecutar los gates requeridos de macOS y
  Windows.
- Stable requiere un RC probado en ambas plataformas.
- No se publica una plataforma como stable ignorando la otra.
- Los hallazgos vuelven al correctivo focalizado correspondiente; no reabren
  por sí solos el roadmap posterior.

### Trabajo posterior al checkpoint

Fase 2E queda **DIFERIDA / NOT STARTED**: `master.raw` no está limitado por
RIFF, `source.wav` sigue siendo WAV, no se elige RF64/W64/segmentación sin
fixture/evidencia y la truncación silenciosa está prohibida. Sólo se adelanta
si el gate de clase larga demuestra que el contrato actual bloquea una
duración razonable. Fases 3, 4 y 5 permanecen fuera de esta release; no se
asignan números de versión futuros.

## Fase 3 — ASR cancelable, backlog e idioma (roadmap posterior a v0.8.0)

Estado: **DIFERIDA**; no forma parte de la frontera estable actual ni bloquea
el checkpoint salvo que un hallazgo vuelva al correctivo focalizado.

Objetivo: eliminar waits/retries infinitos y alucinaciones de no-speech cerca de inferencia.

- [ ] Separar descarga cancelable/reanudable de carga nativa en worker; conservar integridad y progreso.
- [ ] Implementar prewarm con owner de aplicación y lifecycle explícito.
- [ ] Reemplazar ring como fuente de verdad por timeline durable y cursor por timestamps.
- [ ] Añadir circuit breaker y estado `recordingWithoutAsr`.
- [ ] Integrar VAD streaming y política de aceptación por backend.
- [ ] Exponer/usar señales no-speech/logprob de Whisper cuando el binding lo permita.
- [ ] Ejecutar gate es/en/fr con silencio, ruido, otro idioma y vocabulario técnico.
- [ ] Decidir backend macOS a partir del gate; Parakeet no avanza por presunción.

Exit gate: cancelación/worker fault no pierde audio; no hay retry infinito; ningún fixture sin voz produce texto; los tres idiomas cumplen el contrato acordado.

## Fase 4 — Speakers estables y revisión no destructiva (roadmap posterior a v0.8.0)

Estado: **DIFERIDA**; el overhaul completo de speakers no es requisito de
v0.8.0.

Objetivo: corregir mapping `Persona 0` y hacer que ML proponga mientras la persona decide.

- [ ] Introducir `SpeakerID`/`SegmentID` estables y separar `EngineClusterID`.
- [ ] Persistir proposal diagnostics sin confidence inventada.
- [ ] Implementar precedencia del overlay y reconciliación temporal con conflictos a review.
- [ ] Implementar rename, merge reversible, reassign/split en límites soportados y professor confirmado.
- [ ] Versionar/calibrar referencias conocidas con threshold, calidad y margen.
- [ ] Extender Windows para embeddings o declarar la diferencia visible hasta que exista evidencia.
- [ ] Agregar fixtures de fallo, una voz, dos voces, overlap y reproceso con correcciones.

Exit gate: ningún fallback produce Persona 0, failure queda unknown, IDs/correcciones sobreviven round-trip/reproceso y el transcript original permanece accesible.

## Fase 5 — Localización y documentación de usuario (roadmap posterior a v0.8.0)

Estado: **DIFERIDA**; la localización completa no es requisito de v0.8.0.

Objetivo: separar idioma de interfaz y transcripción sin ramas ad hoc.

- [ ] Crear String Catalog macOS y `.resx`/satellite resources Windows.
- [ ] Extraer strings visibles, errores y accesibilidad; mantener allowlist mínima.
- [ ] Persistir `interfaceLocale=system|es|en|fr` y refrescar UI en vivo.
- [ ] Verificar que cambiar locale no modifica `transcriptionLanguage` ni estado de sesión.
- [ ] Crear `README.en.md`/`README.fr.md`, enlazar los tres; traducir sólo otras guías realmente orientadas al usuario.
- [ ] Agregar test de igualdad de keysets y detector de literals.

Exit gate: keysets completos, cambio live validado en flujos materiales y documentación navegable en tres idiomas sin duplicar ingeniería.

## Fase 6 — Ejecución de gates de release v0.8.0

Objetivo: ejecutar focused → subsystem y los gates reales de ambas plataformas
que exige el checkpoint, sin convertir pendientes en PASS.

- [ ] Ejecutar suites focused y luego subsystem por plataforma.
- [ ] macOS: build/tests, TCC, CATap app/global con self-exclusion, identidad/rebind,
      consentimiento system output, output-device change, master/source.wav,
      Stop/recovery y ausencia de callbacks.
- [x] Windows W0/W1A/W1B: restore/build/test, lanzamiento, application loopback,
      root/helper replacement/rebind, render endpoint/consent, endpoint change,
      master/manifest/source.wav, durable recovery, Stop single-flight y start
      rejection durante finalización — **PASS**.
- [ ] Ambas: legacy open/reprocess, no autoswitch por fallo de aplicación,
      no suggestion por fallo durable/storage, consentimiento nuevo para
      system output, no silent truncation y fixture de clase larga dentro del
      contrato WAV actual.
- [ ] Registrar SO, hardware, dispositivo, versiones, pasos, resultado y
      artefactos no sensibles.

Exit gate: todos los acceptance criteria de la frontera estable tienen PASS o
un estado físico explícito **PENDING/SKIPPED**; ningún pendiente se presenta
como aprobado y RC no se corta hasta ejecutar los gates requeridos de macOS y
Windows.

## Trabajo posterior a v0.8.0

- 2E/long format sólo si un fixture demuestra que el contrato WAV actual
  bloquea una duración razonable; decidir RF64/W64/segmentación con evidencia.
- ASR/VAD, aceptación cercana al decoder, backlog, circuit breaker y backend
  macOS forced-language.
- Speakers, embeddings, reconciliación y review no destructivo.
- Localización nativa, refresh live y documentación de usuario.
- Transporte IPC exacto de helpers y aislamiento adicional si un gate físico lo
  demuestra necesario.

No se asignan números de versión futuros aquí. Un hallazgo de release vuelve a
su correctivo focalizado; no reabre automáticamente el roadmap.
