# Revisión ClassScribe — 9 y 10 de agosto de 2026

Este documento consolida los cambios realizados sobre ClassScribe en las ramas `codex/simplify-voice-transcription-ui`, `codex/live-editable-transcript` y `codex/fix-live-editor-follow`. El objetivo fue simplificar la experiencia, eliminar controles duplicados y hacer más resilientes la captura, la transcripción, la edición durante la grabación y la recuperación.

## Resultado para el usuario

- Configuración guiada en una sola tarjeta: materia, tipo de clase y fuente.
- Un único control principal contextual para iniciar o detener.
- Pausa de transcripción como control secundario; el audio nunca se pausa por accidente.
- Vocabulario técnico dentro de una opción desplegable.
- Estados y errores escritos en lenguaje de usuario, sin latencia, dBFS, nombres de modelos ni detalles WAV en la vista normal.
- Acciones de texto agrupadas en un menú: copiar, copiar con contexto, exportar, abrir texto y mostrar carpeta.
- Historial y paneles alineados arriba, con estados vacíos legibles.
- Editor de transcripción disponible durante la grabación, sin perder correcciones al llegar texto nuevo.
- Pausas naturales de pensamiento conservadas dentro del mismo párrafo.
- Icono propio de macOS e instalación verificada en `/Applications/ClassScribe.app` y Launch Services.

## Captura de audio

### Inicio confiable

- La captura no se marca activa hasta que el callback haya entregado muestras reales.
- Se aceptan frames silenciosos: el watchdog observa progreso de frames, no volumen, para no confundir una pausa legítima con un fallo.
- Una aplicación recién iniciada puede tardar en aparecer como proceso de audio. ClassScribe espera hasta tres segundos de forma estructurada y cancelable a que CoreAudio publique su `AudioObjectID`.
- Antes de crear hardware se vuelven a comprobar la cancelación y la existencia del PID elegido.
- El primer prompt de permisos de macOS tiene margen suficiente sin producir un falso timeout.

### Ciclo de vida y recuperación

- Los reintentos diferidos de cambio de dispositivo llevan una generación de captura; un bloque viejo no puede reactivar el tap después de Detener.
- Stop es idempotente y drena los callbacks antes de cerrar el descriptor.
- Un fallo terminal finaliza y valida el audio parcial mediante la misma ruta que un stop normal.
- Si la aplicación fuente se cierra o deja de entregar frames, se conserva lo ya grabado y se muestra recuperación accionable.
- Un micrófono desconectado produce un error explícito; no cambia silenciosamente al dispositivo predeterminado.
- Timeout, cancelación o fallo de arranque del micrófono liberan explícitamente el tap, el engine y el WAV.

### Memoria y orden

- Los buffers en vivo pasan por un `AsyncStream` acotado y ordenado en lugar de crear una tarea desestructurada por callback.
- El ring de 45 segundos avanza en tiempo amortizado O(1) y compacta por lotes.
- La fuente completa permanece en el archivo durable; si el consumidor en vivo se retrasa, la retranscripción final conserva la evidencia completa.

## Transcripción

### Modelos e inferencia

- La carga del modelo es single-flight: llamadas concurrentes comparten una sola descarga/carga.
- Cancelar un consumidor no cancela el trabajo compartido de otros consumidores.
- Las predicciones se serializan para evitar solapes entre ASR en vivo y ASR final.
- Stop deja de esperar la inferencia en vivo después de tres segundos, aunque Core ML tarde en observar la cancelación.
- La cola no inicia otra inferencia hasta que la anterior haya terminado realmente.

### Ventanas en vivo

- El cursor solo se confirma después de una transcripción correcta.
- Un error transitorio reintenta la misma ventana con backoff acotado.
- Si una ventana ya expiró del ring, se rebasa a una ventana completa reciente en vez de confirmar audio truncado.
- Pausar durante una inferencia descarta el resultado tardío y mantiene el estado pausado.
- Al recuperarse ASR se limpia únicamente el error que pertenecía a la transcripción en vivo.
- La transcripción completa del archivo es la fuente final y recupera cualquier tramo omitido por la vista en vivo.

### Edición en vivo y continuidad

- El panel de transcripción es un editor durante la captura: se puede seleccionar, borrar y escribir sin detener el audio ni ASR.
- La rama ASR y la rama editada se mantienen separadas. Cada ventana nueva aporta solo su sufijo; nunca repone palabras borradas ni sobrescribe correcciones humanas.
- Un editor AppKit conserva todos los rangos de selección UTF-16, la afinidad del cursor y el viewport cuando la persona edita. Los sufijos ASR se agregan sin entrar en Undo y se difieren durante la composición de acentos o IME.
- El modo inicial **Siguiendo** baja automáticamente con cada frase. Foco, escritura o scroll humano cambia a **Revisando**; perder el foco no lo revierte. **Seguir en vivo** o **Ver texto nuevo** vuelve al final de forma explícita.
- La edición se guarda con un debounce de 300 ms y se fuerza a disco al perder foco, cambiar de sesión, pausar, detener o crear un checkpoint. Un marcador interno conserva incluso la decisión de dejar **Mi edición** vacía.
- Después del procesamiento final, **Mi edición** conserva el texto corregido y permite compararlo con **Profesor** y **Todos los hablantes**.
- Una pausa inferior a cuatro segundos no crea un párrafo nuevo. Una pausa de al menos cuatro segundos solo lo crea si el fragmento anterior cierra una oración; esta política evita saltos de línea durante pausas de pensamiento.
- La salida final agrupa segmentos consecutivos de la misma voz y separa un cambio de hablante o una pausa larga. SRT conserva la segmentación temporal original.

### Procesamiento final

- El vocabulario técnico es una mejora opcional: si falla, continúa la transcripción base.
- La preparación de un reintento es single-flight y conserva el estado ocupado hasta terminar cualquier reparación RAW/WAV en curso.
- Cancelar un reintento invalida el trabajo de sesión y conserva el mejor texto y audio disponibles.
- La diarización corre en un helper separado con cancelación, timeout y escalamiento `TERM` → `KILL`.
- Un fallo de diarización deja la transcripción completa disponible y la sesión reintentable.

## Archivos principales

| Área | Archivos |
|---|---|
| Interfaz | `app/MeetingTranscriber/ClassScribeSources/ContentView.swift`, `app/MeetingTranscriber/ClassScribeSources/LiveTranscriptEditor.swift`, `app/MeetingTranscriber/ClassScribeTests/ContentViewPresentationTests.swift`, `app/MeetingTranscriber/ClassScribeTests/LiveTranscriptEditorTests.swift` |
| Captura | `app/MeetingTranscriber/ClassScribeSources/AudioCapture.swift`, `app/MeetingTranscriber/ClassScribeTests/AudioValidationTests.swift` |
| AudioTap | `tools/audiotap/Sources/AppAudioCapture.swift`, `tools/audiotap/Sources/AppAudioCapture+PIDTranslation.swift`, `tools/audiotap/Sources/MicCaptureHandler.swift`, `tools/audiotap/Sources/CaptureLifecycleGate.swift` |
| ASR | `app/MeetingTranscriber/ClassScribeSources/Inference.swift`, `app/MeetingTranscriber/ClassScribeSources/TranscriptLogic.swift`, `app/MeetingTranscriber/ClassScribeSources/LiveTranscriptEditing.swift`, `app/MeetingTranscriber/ClassScribeTests/TranscriptionReliabilityTests.swift`, `app/MeetingTranscriber/ClassScribeTests/LiveTranscriptEditingTests.swift` |
| Coordinación | `app/MeetingTranscriber/ClassScribeSources/ClassScribeModel.swift`, `app/MeetingTranscriber/ClassScribeTests/FinalProcessingResilienceTests.swift` |
| Diarización | `app/MeetingTranscriber/ClassScribeSources/DiarizationProcessRunner.swift`, `app/MeetingTranscriber/ClassScribeTests/DiarizationProcessRunnerTests.swift` |
| Icono/bundle | `app/MeetingTranscriber/ClassScribeAssets/AppIcon.png`, `app/MeetingTranscriber/ClassScribeSources/Info.plist`, `scripts/run_app.sh` |

## Validación realizada

- 114 pruebas aprobadas con `-strict-concurrency=complete`; cinco fixtures opt-in omitidos en el pase integrado.
- Fixture Parakeet real en español aprobado.
- Fixture de diarización real con al menos dos voces aprobado.
- Captura CATap real y audible de `afplay` aprobada en el pase integrado.
- La corrección de registro transitorio CATap pasó cuatro ejecuciones reales, tres consecutivas.
- Build Release firmado y verificado con `codesign --verify --deep --strict`.
- QA visual de la interfaz y del CTA mediante el árbol de accesibilidad de macOS.
- Bundle con `AppIcon.icns` generado, instalado, registrado y abierto desde `/Applications/ClassScribe.app`.
- `git diff --check` limpio.

El script de lint no pudo ejecutarse en esta máquina porque `swiftlint` y `swiftformat` no están instalados. La suite aislada XCTest de AudioTap tampoco puede ejecutarse con la instalación parcial de Command Line Tools; sus fuentes sí compilan y enlazan dentro de ClassScribe.

## Validación no realizada

No se ejecutó la prueba física de micrófono de 60 segundos porque capturaría audio ambiental. Los casos de permiso denegado, micrófono desconectado, primer buffer, timeout, cancelación y limpieza tienen cobertura automatizada. La prueba física sigue disponible como opt-in en `CaptureIntegrationTests.swift`.

## Commits

- `198c44e` — `fix(app): harden capture and transcription lifecycle`
- `4dedeb6` — `refactor(app): simplify the recording workflow`
- `4dad662` — `feat(app): add ClassScribe application icon`
- `9c70bb8` — `docs(app): document the ClassScribe reliability release`
- `4b2b5a6` — `test(app): remove scheduler-sensitive timing assertions`
- `bd1a59f` — `feat(app): support live transcript corrections`
- `aca7832` — `fix(app): preserve live editor position while transcribing`

## Instalación local

```bash
./scripts/run_app.sh --build-only
ditto app/MeetingTranscriber/.build/ClassScribe-Dev.app /Applications/ClassScribe.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f /Applications/ClassScribe.app
open -n /Applications/ClassScribe.app
```

El bundle instalado usa el identificador `app.classscribe.local` y queda visible como **ClassScribe** en Launchpad.
