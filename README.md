# ClassScribe

ClassScribe es una aplicación nativa para macOS que graba y transcribe clases universitarias en español, completamente en el dispositivo. Captura **una aplicación elegida** o **un micrófono elegido**, nunca ambos automáticamente. El audio, las transcripciones y las referencias de voz permanecen en la Mac.

> Obtén permiso del profesor y de las demás personas antes de grabar. Cumple las normas de tu universidad y la legislación aplicable.

## Privacidad

- No hay cuentas, telemetría, servidores ni base de datos remota.
- No usa OpenAI, Claude, Ollama, LM Studio ni ninguna API externa.
- Solo se accede a Internet durante la primera descarga de FluidAudio y de los modelos Core ML.
- Audio, texto, etiquetas y embeddings se guardan con permisos de propietario bajo `~/Library/Application Support/ClassScribe/`.
- “Copiar para ChatGPT” solo copia texto al portapapeles; no abre ni automatiza ChatGPT.

## Origen y licencia

ClassScribe adapta [Meeting Transcriber](https://github.com/pasrom/meeting-transcriber), copyright 2025 pasrom, bajo licencia MIT. Se conserva [LICENSE](LICENSE), la atribución y el historial Git. Se reutiliza su biblioteca `AudioTapLib`; los generadores de protocolos, proveedores Claude/OpenAI, resúmenes, RPC y detección automática del producto original están fuera del target ClassScribe y no se compilan.

## Requisitos

- Apple Silicon (probado para M1).
- macOS 14.2 o posterior; la máquina de desarrollo usa macOS 15.3.2.
- Xcode completo 16.x recomendado, o Command Line Tools con Swift 6.1.
- Aproximadamente 1–2 GB libres para build, cachés y modelos.
- Conexión a Internet para la primera descarga de modelos; luego funciona localmente.

Dependencias:

- SwiftUI, AVFoundation, AppKit y Core Audio.
- `AudioTapLib`/`CATapDescription` para audio aislado por proceso.
- FluidAudio 0.15.5, Parakeet TDT v3 multilingüe y OfflineDiarizer/WeSpeaker.

## Compilar y ejecutar

Desde el repositorio:

```bash
./scripts/run_app.sh
```

El script fija FluidAudio 0.15.5, prepara una solución local para la instalación inconsistente de `PackageDescription` detectada en esta Mac, compila con dos trabajos (adecuado para 8 GB), arma y firma ad hoc `app/MeetingTranscriber/.build/ClassScribe-Dev.app`, y la abre.

Solo compilar:

```bash
./scripts/run_app.sh --build-only
```

Abrir en Xcode: ejecuta primero `./scripts/bootstrap_dependencies.sh`, abre `app/MeetingTranscriber/Package.swift`, elige el esquema ClassScribe y Run. Si `xcode-select` apunta a Command Line Tools después de instalar Xcode:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## Modelos

Parakeet TDT v3 y los modelos de diarización se descargan automáticamente en la primera transcripción/diarización mediante FluidAudio. El estado “Descargando/cargando modelos” es normal. Si faltan o falla la descarga, la grabación continúa y la interfaz informa el error sin cerrar la app. Los modelos no se guardan en Git.

## Permisos

### Clase online

Selecciona Chrome, Safari, Teams, Zoom u otra aplicación en ejecución. Core Audio solicita autorización de captura de audio cuando macOS lo requiera. ClassScribe incluye el PID raíz y sus procesos auxiliares, imprescindible para Google Meet en Chrome y Teams. La lista de PIDs contiene solamente la app elegida y excluye ClassScribe, por lo que no captura el micrófono, otras apps ni su propio audio.

### Clase presencial

Selecciona el micrófono. macOS pedirá permiso; si se negó antes, ve a **Ajustes del Sistema → Privacidad y seguridad → Micrófono**. Este modo no crea un tap de audio interno. El medidor debe moverse al hablar.

## Uso

1. Escribe materia y, opcionalmente, vocabulario técnico separado por comas.
2. Elige “Clase online” o “Clase presencial” y la fuente.
3. Pulsa “Iniciar clase”. El punto rojo, temporizador y medidor confirman la grabación.
4. La transcripción usa ventanas de 7 s con salto de 5,5 s (1,5 s de solapamiento). El texto tenue/cursivo es provisional; una pausa de voz confirma el fragmento. La interfaz muestra demora estimada.
5. “Pausar transcripción” detiene inferencia, no la grabación. “Reanudar” vuelve a procesar ventanas recientes.
6. “Detener clase” valida el WAV, retranscribe el archivo completo y ejecuta diarización final. El texto vivo permanece hasta que la versión final lo reemplaza.
7. Al terminar, la persona con más tiempo de habla se marca como profesor automático/provisional, salvo que una referencia local de voz coincida con suficiente similitud.

## Identificar y corregir al profesor

- Cada tarjeta muestra Persona N, fragmentos recientes, tiempo y confianza.
- Pulsa “Este es el profesor” en cualquier tarjeta. La pestaña Profesor se regenera sin borrar las demás voces.
- “Calibrar voz del profesor” toma 20 s de la fuente activa; pide que hable principalmente el profesor y guarda solo un embedding local.
- Los fragmentos de baja confianza o con voces superpuestas van a “Revisar”. Puedes asignarlos manualmente al profesor.
- “Todos los hablantes” siempre conserva ambos lados de la decisión.

## Exportar e historial

La app genera automáticamente:

```text
~/Library/Application Support/ClassScribe/Classes/AAAA-MM-DD_HHMMSS_Materia/
  source.wav
  live-transcript.json
  professor.txt
  professor.md
  professor.srt
  all-speakers.txt
  all-speakers.json
  review.json
  speakers.json
  professor-voice-reference.json   # cuando existe una referencia
  metadata.json
```

“Exportar” permite elegir otro destino para TXT, Markdown o SRT. “Abrir carpeta” y las entradas del historial muestran los archivos en Finder. El audio original nunca se borra automáticamente.

## Pruebas

```bash
./scripts/bootstrap_dependencies.sh
export SWIFTPM_CUSTOM_LIBS_DIR="$(./scripts/prepare_local_toolchain.sh)"
swift test --package-path app/MeetingTranscriber -j 2 \
  -Xswiftc -resource-dir -Xswiftc "$PWD/.toolchain/usr/lib/swift"
```

Las pruebas puras cubren deduplicación de ventanas, confirmación tras pausa, filtro reversible al cambiar profesor, revisión de superposición, TXT/Markdown/SRT, WAV legible y similitud coseno. Las pruebas físicas de micrófono y audio de aplicación requieren permisos TCC e interacción con una fuente audible; no se simulan como éxitos en CI.

Fixtures y pruebas locales de modelos:

```bash
./scripts/generate_classscribe_fixtures.sh

CLASSSCRIBE_RUN_MODEL_TESTS=1 \
CLASSSCRIBE_TEST_AUDIO="$PWD/.test-fixtures/spanish-known.wav" \
swift test --package-path app/MeetingTranscriber -j 2 \
  -Xswiftc -resource-dir -Xswiftc "$PWD/.toolchain/usr/lib/swift" \
  --filter spanishModelFixture

CLASSSCRIBE_RUN_DIARIZATION_TESTS=1 \
CLASSSCRIBE_TWO_SPEAKER_AUDIO="$PWD/.test-fixtures/two-speakers.wav" \
swift test --package-path app/MeetingTranscriber -j 2 \
  -Xswiftc -resource-dir -Xswiftc "$PWD/.toolchain/usr/lib/swift" \
  --filter twoSpeakerFixture
```

Con `SWIFTPM_CUSTOM_LIBS_DIR` exportado como en el bloque anterior, la captura aislada puede repetirse después de autorizar **Audio del sistema**:

```bash
CLASSSCRIBE_RUN_APP_CAPTURE_TEST=1 \
CLASSSCRIBE_TEST_AUDIO="$PWD/.test-fixtures/spanish-known.wav" \
swift test --package-path app/MeetingTranscriber -j 2 \
  -Xswiftc -resource-dir -Xswiftc "$PWD/.toolchain/usr/lib/swift" \
  --filter applicationCaptureFixture
```

La prueba de micrófono dura 60 s y solo se habilita cuando el host ya está autorizado:

```bash
CLASSSCRIBE_RUN_MIC_CAPTURE_TEST=1 swift test \
  --package-path app/MeetingTranscriber -j 2 \
  -Xswiftc -resource-dir -Xswiftc "$PWD/.toolchain/usr/lib/swift" \
  --filter microphoneCaptureFixture
```

Resultados observados el 6 de agosto de 2026: Parakeet aprobó el fixture español (la primera preparación completa tardó 388 s) y FluidAudio separó dos voces en el fixture representativo de 49,5 s. La prueba CATap quedó esperando autorización TCC y la de micrófono confirmó permiso denegado; por ello esas dos rutas físicas no se declaran aprobadas en esta máquina todavía.

## Limitaciones conocidas del MVP

- La diarización y las tarjetas de varios hablantes se actualizan al detener la clase; durante la grabación se conserva y muestra el texto vivo, pero no se promete diarización verdaderamente streaming.
- La separación de voces, superposiciones y reconocimiento son de mejor esfuerzo. Los casos inseguros se conservan en Revisar.
- La primera carga de modelos puede tardar varios minutos y consumir memoria significativa en una Mac de 8 GB.
- Editar el texto visible no cambia el audio ni el JSON estructurado; la exportación TXT manual respeta la edición del profesor, mientras SRT conserva tiempos/segmentos finales.
- En esta máquina no hay Xcode completo y `xcodebuild` no puede ejecutarse. El build por SwiftPM usa el SDK 15.5 de Command Line Tools; instala/selecciona Xcode para verificar el flujo de Xcode.
- La suite XCTest heredada de `tools/audiotap` tampoco está disponible con estos Command Line Tools (`no such module XCTest`), aunque la biblioteca sí compila y enlaza dentro del target ClassScribe.
- La ejecución actual de Codex no pudo operar los diálogos de privacidad de macOS: la prueba automática de audio de aplicación quedó esperando TCC y el host de pruebas de micrófono no estaba autorizado. Abre ClassScribe, inicia una grabación de cada modo y concede los permisos antes de una clase real.

## GitHub

Los modelos, grabaciones, transcripciones, embeddings, logs, secretos, DerivedData y datos Xcode de usuario están ignorados. Para subir cambios posteriores:

```bash
git add -A
git commit -m "describe el cambio"
git push
```
