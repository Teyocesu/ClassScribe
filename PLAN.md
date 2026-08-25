# Plan de ClassScribe v0.8.0

Fecha: 2026-08-24

Estado canónico: Fase 1A **APPROVED**; Fase 1B **APPROVED arquitectónicamente** (runtime process-backed macOS **PASS**; runtime Windows **PENDING / SKIPPED — dotnet unavailable**); Fase 1C **ARCHITECTURE APPROVED** (CATap subsystem físico macOS **PASS**; micrófono macOS physical gate pending — TCC; Windows physical/runtime gate pending; process isolation **INCONCLUSIVE / evidence-gated**, no requerida por la evidencia actual). La arquitectura de Fase 1 está **APPROVED**; los physical release gates permanecen pendientes; Fase 2 **NOT STARTED**.
SPEC canónica: [`docs/specs/v0.8.0.md`](docs/specs/v0.8.0.md)

Este documento es mutable: ordena trabajo pequeño y verificable. No redefine requisitos. Cada fase se valida localmente con el patrón `focused → subsystem`; los gates con TCC, hardware, llamada real o Windows físico están definidos en la SPEC.

## Fase 0 — Baseline y contrato

Estado: **completada en esta sesión, sólo documentación**

- [x] Inventariar targets activos y documentación existente.
- [x] Recuperar el informe previo de startup y contrastar cada hallazgo con el `HEAD` actual.
- [x] Auditar macOS/Windows: captura, ASR/idioma, diarización, persistencia y localización.
- [x] Investigar APIs nativas y capacidades de FluidAudio, Whisper y sherpa-onnx.
- [x] Crear una SPEC canónica y reglas permanentes mínimas del repo.

Salida: SPEC, PLAN y `AGENTS.md`. No se modificó código de producto.

## Fase 1 — Estado, schema y supervisión

Estado: **APPROVED** en arquitectura y gates locales disponibles. Los gates físicos de release permanecen pendientes.

Objetivo: crear las fronteras que permiten implementar features sin estados falsos ni datos destructivos.

- [x] Introducir IDs de intento/generation y ejes `CapturePhase`, `AsrPhase`, `SessionPhase` sin strings localizadas persistidas.
- [x] Definir schema v2 aditivo y golden fixtures de sesiones macOS/Windows v0.7.
- [x] Separar transcript ASR original, propuestas de diarización y overlay de correcciones.
- [x] Prototipar protocolo versionado y supervisor del worker ASR en ambas plataformas (serialización y terminalización exactly-once; arquitectura aprobada, runtime Windows pendiente).
- [x] Probar cancel, crash, heartbeat, deadline y callback tardío con worker falso y transporte process-backed macOS; macOS runtime **PASS**, Windows runtime **PENDING / SKIPPED — dotnet unavailable**.
- [ ] Caracterizar físicamente si setup/teardown de captura requiere aislamiento de proceso.

Exit gate: cancelación determinista por fase, una sesión legacy abre sin reescritura y un worker colgado no bloquea stop ni el intento siguiente.

Progreso aprobado arquitectónicamente de Fase 1B: se añadieron envelopes versionados, negociación explícita,
supervisores con una frontera serializada por plataforma, transporte process-backed y fake
workers deterministas para macOS y Windows. El helper real macOS cubre éxito, crash, malformed
frame, EOF, heartbeat/deadline, cancelación ignorada y A→B con muerte del proceso. El typecheck
focalizado y el runtime process-backed macOS pasan; SwiftPM no puede cargar el manifest local y
`dotnet` no está instalado, por lo que el runtime Windows queda explícitamente **PENDING / SKIPPED**. El
lifecycle Windows de setup/exit quedó protegido contra la carrera de inicialización, con tests
deterministas de exit-wins, terminate-wins y setup normal.

Progreso aprobado de arquitectura de Fase 1C: la ruta real macOS de aplicación mediante CATap/AudioTapLib
se ejecutó con audio sintético local a través del nuevo `CaptureNativeExecutor`; setup, primer frame,
stop/teardown, ausencia de callbacks posteriores, stop inmediato y dos ciclos A→B retornaron dentro
de los tiempos medidos. El control plane quedó desacoplado del setup/stop síncrono y cada native work
lleva `SessionAttemptID`; una segunda operación espera cleanup A en la cola serial, sin solapar taps.
El subsystem físico CATap macOS es **PASS**. La fault injection determinista mostró que cancelación/control
plane siguen respondiendo mientras una llamada no cooperativa ocupa el owner, pero B necesariamente
espera su retorno; process isolation queda **INCONCLUSIVE / evidence-gated** y no es requerida por la
evidencia actual. El micrófono queda physical gate pending — `SKIPPED — TCC` porque el host local está
en `.notDetermined`; Windows queda physical/runtime gate pending — `SKIPPED — PHYSICAL WINDOWS / dotnet unavailable`
porque `dotnet` no está instalado. El detalle reproducible existente está en
[`docs/characterization/fase-1c-capture.md`](docs/characterization/fase-1c-capture.md).

## Fase 2 — Captura confiable y audio del equipo

Estado: **NOT STARTED**.

Objetivo: diferenciar transporte/señal y agregar global con consentimiento explícito y master fiel.

- [ ] Implementar clasificación no-callbacks/silencio/audible/voz con fake clock y fixtures.
- [ ] macOS: reenumeración/reconciliación de PIDs y validación de AudioObjectIDs traducidos.
- [ ] Windows: identidad estable de app y revalidación de root reemplazado.
- [ ] Implementar global CATap y WASAPI loopback con exclusión/self y device lifecycle correspondientes.
- [ ] Implementar modal de privacidad y CTA `Capturar audio del equipo`, sin transición automática posible.
- [ ] Separar master source-rate/stereo del derivado ASR 16 kHz mono.
- [ ] Elegir RF64/W64 o segmentos después del fixture de clase larga.

Exit gate: los tests prueban que global es inalcanzable sin consentimiento; fixtures/gates físicos demuestran señal, PID lifecycle, master fidelity y recuperación.

## Fase 3 — ASR cancelable, backlog e idioma

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

## Fase 4 — Speakers estables y revisión no destructiva

Objetivo: corregir mapping `Persona 0` y hacer que ML proponga mientras la persona decide.

- [ ] Introducir `SpeakerID`/`SegmentID` estables y separar `EngineClusterID`.
- [ ] Persistir proposal diagnostics sin confidence inventada.
- [ ] Implementar precedencia del overlay y reconciliación temporal con conflictos a review.
- [ ] Implementar rename, merge reversible, reassign/split en límites soportados y professor confirmado.
- [ ] Versionar/calibrar referencias conocidas con threshold, calidad y margen.
- [ ] Extender Windows para embeddings o declarar la diferencia visible hasta que exista evidencia.
- [ ] Agregar fixtures de fallo, una voz, dos voces, overlap y reproceso con correcciones.

Exit gate: ningún fallback produce Persona 0, failure queda unknown, IDs/correcciones sobreviven round-trip/reproceso y el transcript original permanece accesible.

## Fase 5 — Localización y documentación de usuario

Objetivo: separar idioma de interfaz y transcripción sin ramas ad hoc.

- [ ] Crear String Catalog macOS y `.resx`/satellite resources Windows.
- [ ] Extraer strings visibles, errores y accesibilidad; mantener allowlist mínima.
- [ ] Persistir `interfaceLocale=system|es|en|fr` y refrescar UI en vivo.
- [ ] Verificar que cambiar locale no modifica `transcriptionLanguage` ni estado de sesión.
- [ ] Crear `README.en.md`/`README.fr.md`, enlazar los tres; traducir sólo otras guías realmente orientadas al usuario.
- [ ] Agregar test de igualdad de keysets y detector de literals.

Exit gate: keysets completos, cambio live validado en flujos materiales y documentación navegable en tres idiomas sin duplicar ingeniería.

## Fase 6 — Integración y release readiness local

Objetivo: cerrar sólo fallos distintos y ejecutar gates que requieren sistemas reales.

- [ ] Ejecutar suites focused y luego subsystem por plataforma.
- [ ] Ejecutar matriz macOS con TCC, Chrome/Teams/Zoom, global, device change y worker faults.
- [ ] Ejecutar matriz Windows física equivalente.
- [ ] Ejecutar clases consentidas de una/dos voces y round-trip de correcciones.
- [ ] Verificar migración/export/reproceso del corpus legacy sin borrado.
- [ ] Actualizar documentación de distribución sólo cuando los artefactos locales estén listos.
- [ ] Registrar riesgos aceptados y gates con versiones exactas.

Exit gate: todos los acceptance criteria tienen evidencia local o gate físico explícitamente pendiente. Ningún pendiente se presenta como aprobado.

## Decisiones a tomar con evidencia

1. Backend macOS tras el gate forced-language.
2. Contenedor master largo tras medir formatos/tamaños reales.
3. Transporte IPC exacto de cada helper.
4. Política de locale inicial para instalaciones existentes.
5. Thresholds VAD/no-speech/embeddings versionados por backend.
6. Aislamiento de captura si la caracterización demuestra cancelación no cooperativa.

No hay una pregunta bloqueante antes de Fase 1. No se salta directamente a features de Fases 2–5 sin cerrar estado, cancelación y persistencia de Fase 1.
