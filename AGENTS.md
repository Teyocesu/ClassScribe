# Reglas permanentes del repositorio

- El target activo de macOS vive en `app/MeetingTranscriber/ClassScribeSources`; `Sources` es referencia upstream y no debe confundirse con producto.
- El producto Windows vive en `app/ClassScribe.Windows`; conservar invariants comunes sin forzar APIs o abstracciones de captura idénticas.
- La SPEC activa enlazada desde `PLAN.md` define requisitos; `PLAN.md` sólo ordena la implementación.
- Todo cambio de persistencia debe leer sesiones históricas y preservar audio, transcript original y correcciones humanas.
- Validar `focused → subsystem`; los claims de TCC, audio, hardware o Windows físico requieren un gate reproducible real.
