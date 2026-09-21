# Plan de ClassScribe — correctivo post-v0.9.0

Baseline actual: `main` en v0.9.0 (`VERSION = 0.9.0`).
SPEC activa: [`docs/specs/post-v0.9.0-corrective.md`](docs/specs/post-v0.9.0-corrective.md)

Este documento es mutable y corto: ordena el correctivo vigente. No redefine
requisitos y no duplica historia. Historia v0.8.0:
[`docs/specs/v0.8.0.md`](docs/specs/v0.8.0.md),
[`docs/characterization/`](docs/characterization/) e historial Git.

## Fase 1 — Correctness (implementada)

- Windows: `ApplySpeakerCorrectionAsync` captura snapshot de attempt, sesión,
  carpeta, overlay y objetivo antes del primer `await`; publica sólo si la
  identidad sigue vigente. FIFO de correcciones, RMW del overlay serializado
  por carpeta, aislamiento A→B.
- Windows: `ApplyProfessorSelectionAsync` y `SaveEditsAsync` capturan
  identidad (attempt, carpeta) antes del gate y son no-op si la sesión
  visible cambió; tras el gate revalidan, leen estado fresco y persisten.
- Regresiones deterministas sin sleeps: A→B para correcciones (2 tests),
  profesor en espera con apertura de B, y guardado en espera con apertura
  de B. Orden FIFO de correcciones rápidas cubierto.
- VAD fail-open con presupuesto TOTAL de 15 s por llamada pública en ambas
  plataformas (macOS: un único deadline compartido entre resample, load e
  inferencia). Timeout/error/cancelación interna marca VAD no disponible
  (sticky) y continúa por ASR; sin retry loops; caller cancellation primero.
- Localización: literales activos de live/retry con claves es/en/fr y tests
  de keysets. Fixes del gate Windows v0.9.0 preservados (guards de
  `MergeTargets`, tipo concreto de operaciones de review, `Count` en
  proyección restaurada, ajustes de tests).

## Fase 2 — Performance final (implementada, no medida físicamente)

- Windows: overlap ASR final + diarización y semántica
  checkpoint/tail/full intactas; sin cambios en esta fase.
- macOS: ASR final + diarización como child tasks estructuradas con el
  audio ya cerrado; speaker attribution espera ambos; transcript ASR
  persistido como `diarizing` (nunca `complete`) antes de esperar speakers;
  recovery ante fallo de diarización conservada.
- Diagnostics opt-in (`CLASSSCRIBE_PERF_DIAGNOSTICS=1`), monotónicos,
  locales, sin contenido sensible.
- La mejora está inferida por eliminación de la dependencia serial
  demostrada; sin benchmarks cold/warm ni medición de runtime.

## Fase 3 — Cleanup con evidencia (ejecutado)

Eliminado sin cambio de comportamiento: scaffolding ASR muerto
(protocols, transports, supervisors, lifecycle, fakes) y sus
tests/fixtures exclusivos en ambas plataformas; `loadedModelPath`;
`CLAUDE.md`/`CONTRIBUTING.md`; `docs/architecture-macos.md`;
`docs/automation-api.md`; `scripts/configure-tag-ruleset.sh`;
`scripts/generate_social_preview.py`. Sincronizados `README.md`,
`docs/WINDOWS.md` (modelo Windows real) y `docs/DISTRIBUTION.md`
(repositorio público). Detalle en la SPEC activa.

## Validación

- Disponible local: `git diff --check`, revisión de referencias, checks de
  localización/XML, revisión del diff contra la SPEC.
- BLOCKED por host: `dotnet` ausente; parser SwiftPM local incompatible con
  `swiftLanguageModes: [.v6]`; gates físicos (TCC, audio, hardware) sin
  ejecutar en este entorno. No se modifican manifests ni tooling para
  compensar el host. CI no forma parte del gate de este workflow.
- Verde no debilitado: sin skips, assertions, suppressions, thresholds,
  catches vacíos ni fallbacks nuevos; los fixes de gate v0.9.0 son baseline.

## Follow-ups diferidos (no borrar por entusiasmo)

- `Sources/` y `Tests/` upstream, `site/`, `Casks/`, `tools/mt-cli`,
  `tools/meeting-simulator`, E2E legacy, `.claude/skills/distribution`,
  `downloadProgress` write-only de macOS, `docs/social-preview.png`.
- Medición de runtime P0 (frío/caliente, p50/p95) con gates físicos reales.
- Detector general de literals (fase de localización completa).
- Roadmap posterior (2E/long format, ASR/VAD avanzado, speakers, i18n
  completa): sin números de versión asignados.
