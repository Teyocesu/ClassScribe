# ClassScribe

ClassScribe es una aplicación nativa para macOS y Windows que graba y transcribe clases universitarias en **español, inglés o francés**, completamente en el dispositivo. Captura **una aplicación elegida** o **un micrófono elegido**, nunca ambos automáticamente. El audio, las transcripciones y las referencias de voz permanecen en tu equipo.

La revisión de interfaz, captura, transcripción, edición en vivo, instalación e icono realizada el 9 y 10 de agosto de 2026 está documentada en [docs/classscribe-2026-08-09.md](docs/classscribe-2026-08-09.md).

> Obtén permiso del profesor y de las demás personas antes de grabar. Cumple las normas de tu universidad y la legislación aplicable.

## Descargar e instalar

La forma recomendada es abrir [GitHub Releases](https://github.com/Teyocesu/ClassScribe/releases/latest) y descargar el archivo de tu sistema:

- **Windows 11 x64:** `ClassScribe-vX.Y.Z-windows-x64-setup.exe`. Abre el instalador y sigue el asistente; no requiere .NET, Git ni herramientas de desarrollo. También hay un ZIP portable.
- **macOS 14.2+ con Apple Silicon:** `ClassScribe-vX.Y.Z-arm64.dmg`. Ábrelo y arrastra ClassScribe a Aplicaciones.
- Cada descarga incluye un `.sha256` para comprobar su integridad. Las builds actuales no tienen firma comercial: Windows SmartScreen o macOS Gatekeeper pueden pedir una confirmación adicional.

El repositorio y sus Releases son públicos; cualquier persona puede consultar el código y descargar los instaladores publicados.

## Privacidad

- No hay cuentas, telemetría, servidores ni base de datos remota.
- No usa OpenAI, Claude, Ollama, LM Studio ni ninguna API externa.
- Solo se accede a Internet durante la primera descarga verificada de los modelos locales.
- Audio, texto, etiquetas y embeddings se guardan en `~/Library/Application Support/ClassScribe/` (macOS) o `%LOCALAPPDATA%\ClassScribe\` (Windows).
- “Copiar para ChatGPT” solo copia texto al portapapeles; no abre ni automatiza ChatGPT.

## Origen y licencia

ClassScribe adapta [Meeting Transcriber](https://github.com/pasrom/meeting-transcriber), copyright 2025 pasrom, bajo licencia MIT. Se conserva [LICENSE](LICENSE), la atribución y el historial Git. Se reutiliza su biblioteca `AudioTapLib`; los generadores de protocolos, proveedores Claude/OpenAI, resúmenes, RPC y detección automática del producto original están fuera del target ClassScribe y no se compilan.

## Requisitos

### Windows

- Windows 11 x64 (versión 21H2/build 22000 o posterior).
- Aproximadamente 2 GB libres para la aplicación, sesiones y modelos.
- Conexión a Internet para la primera descarga de modelos; luego funciona localmente.

### macOS

- Apple Silicon (probado para M1).
- macOS 14.2 o posterior; la máquina de desarrollo usa macOS 15.3.2.
- Command Line Tools con Swift 6.1 para el flujo local. GitHub Actions usa Xcode 16.x para las comprobaciones que lo requieren; no hace falta instalar Xcode completo en la Mac de uso.
- Aproximadamente 1–2 GB libres para build, cachés y modelos.
- Conexión a Internet para la primera descarga de modelos; luego funciona localmente.

Dependencias:

- SwiftUI, AVFoundation, AppKit y Core Audio.
- `AudioTapLib`/`CATapDescription` para audio aislado por proceso.
- FluidAudio 0.15.5, Parakeet TDT v3 multilingüe y OfflineDiarizer/WeSpeaker.

## Compilar y ejecutar en macOS

Desde el repositorio:

```bash
./scripts/run_app.sh
```

El script resuelve FluidAudio 0.15.5 en una versión fija, compila con dos trabajos, arma y firma ad hoc `app/MeetingTranscriber/.build/ClassScribe-Dev.app`, genera `AppIcon.icns`, cierra cualquier proceso anterior llamado ClassScribe y abre una única instancia nueva con `open -n`. El commit y timestamp quedan embebidos en el bundle y disponibles como ayuda accesible del encabezado. El bundle incluye un helper firmado para aislar la diarización.

Solo compilar:

```bash
./scripts/run_app.sh --build-only
```

`./scripts/pre-push.sh --with-tests` repite el build Release y las pruebas disponibles con el toolchain instalado. En esta Mac, el script prepara automáticamente un mirror local ignorado para compensar el SDK incompleto de Command Line Tools.

### Instalar en Aplicaciones y Launchpad

Después de compilar, copia el bundle firmado y regístralo con Launch Services:

```bash
ditto app/MeetingTranscriber/.build/ClassScribe-Dev.app /Applications/ClassScribe.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f /Applications/ClassScribe.app
open -n /Applications/ClassScribe.app
```

La app aparece como **ClassScribe** en Finder y Launchpad con el icono incluido en `app/MeetingTranscriber/ClassScribeAssets/AppIcon.png`.

## Distribución

Las versiones para compartir se publican como assets de GitHub Releases en el repositorio público. Un tag `vX.Y.Z` que coincida con `VERSION` compila, prueba y publica el DMG de macOS, el instalador de Windows, un ZIP portable y sus checksums. La guía está en [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md).

### Compilar el paquete de Windows

Desde PowerShell en Windows 11, con el SDK .NET 10 e Inno Setup 6 o posterior:

```powershell
./scripts/build_windows.ps1
```

El script restaura dependencias bloqueadas, compila con analizadores, ejecuta pruebas, publica una app autocontenida, valida el ejecutable y crea los cuatro assets bajo `.build/windows/release/`.

## Modelos

En macOS, Parakeet TDT v3 multilingüe y los modelos de diarización se descargan mediante FluidAudio. En Windows se usa Whisper large-v3-turbo cuantizado, con idioma explícito y vocabulario técnico, más modelos sherpa-onnx para voces. Español, inglés y francés se seleccionan antes de grabar y el idioma queda persistido con la sesión. Las descargas de Windows validan tamaño y SHA-256 antes de cargar código nativo. Si la preparación falla, la grabación se conserva y la interfaz permite reintentar. Los modelos no se guardan en Git.

## Permisos

### Clase online

Selecciona Chrome, Safari, Teams, Zoom u otra aplicación en ejecución. Core Audio solicita autorización de captura de audio cuando macOS lo requiera. ClassScribe incluye el PID raíz y sus procesos auxiliares, imprescindible para Google Meet en Chrome y Teams. La lista de PIDs contiene solamente la app elegida y excluye ClassScribe, por lo que no captura el micrófono, otras apps ni su propio audio.

### Clase presencial

Selecciona el micrófono. macOS pedirá permiso; si se negó antes, ve a **Ajustes del Sistema → Privacidad y seguridad → Micrófono**. Este modo no crea un tap de audio interno. El medidor debe moverse al hablar.

## Uso

1. Escribe la materia y elige Español, English o Français.
2. Elige “Clase online” o “Clase presencial” y la fuente. El único botón principal explica qué dato falta hasta que la configuración sea válida.
3. Si hace falta, despliega “Agregar vocabulario técnico (opcional)” y escribe términos separados por comas.
4. Pulsa “Iniciar grabación”. La app no declara una captura activa hasta recibir frames reales; una fuente silenciosa es válida, pero una fuente sin callbacks produce un error recuperable y accionable.
5. La transcripción aparece en un editor: puedes borrar o corregir palabras mientras la grabación continúa. Las frases nuevas se agregan al final sin restaurar lo que ya corregiste. Internamente usa ventanas de 7 s con salto de 5,5 s (1,5 s de solapamiento); el cursor solo avanza después de un resultado correcto.
6. “Pausar transcripción” detiene inferencia, no la grabación. Un resultado tardío no puede sacar la interfaz del estado pausado.
7. “Detener grabación” guarda el texto, detiene la espera en vivo de forma acotada, finaliza el audio y retranscribe el archivo completo. El texto sigue visible mientras procesa.
8. La transcripción completa se persiste antes de identificar voces. La diarización corre en `ClassScribeDiarizer`, un proceso CPU-only separado y con timeout; si falla, la aplicación principal permanece abierta y permite reintentar.
9. Al terminar, la persona con más tiempo de habla se marca como profesor automático/provisional, salvo que una referencia local de voz coincida con suficiente similitud.

## Ver, copiar y editar

- El panel derecho es editable desde que empieza la grabación. Cada corrección humana prevalece sobre el reconocimiento y se guarda mientras escribes.
- Mientras solo observas, la vista sigue automáticamente cada frase nueva. Hacer clic para editar o desplazarse hacia arriba pausa ese seguimiento y conserva exactamente el cursor, la selección y la posición visible aunque ASR siga agregando texto.
- “Seguir en vivo” vuelve al final; si llegaron frases mientras revisabas, el mismo control se presenta como “Ver texto nuevo”. Perder el foco no reactiva el seguimiento por sorpresa.
- Una pausa normal para pensar mantiene la frase en el mismo párrafo. Solo una pausa claramente larga (aproximadamente cuatro segundos) después de una oración terminada inicia otro párrafo; al finalizar, un cambio de hablante también lo separa.
- Si corregiste durante la clase, al terminar queda disponible la pestaña **Mi edición**, seleccionada por defecto, junto con las versiones finales **Profesor** y **Todos los hablantes**.
- “Copiar transcripción” elige, en orden, una edición visible, la versión final del profesor, la final completa y la versión viva/recuperada. No copia vacío si existe texto útil.
- “Copiar para ChatGPT” agrega materia, fecha, duración, modo y fuente. Solo usa el portapapeles.
- El menú de acciones de la transcripción agrupa copiar, exportar, abrir el archivo de texto y mostrar la carpeta en Finder, sin repetir botones en la barra de estado.
- Las ediciones se guardan de forma atómica. TXT y Markdown exportan la edición visible. SRT conserva la versión segmentada con tiempos y muestra una advertencia si hubo edición libre.

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
  live-transcript.txt
  live-transcript.md
  live-transcript.json
  live-transcript-journal.jsonl
  live-transcript-edit.json          # solo cuando hubo una edición en vivo
  professor.txt
  professor.md
  professor.srt
  all-speakers.txt
  all-speakers.md
  all-speakers.json
  review.json
  speakers.json
  professor-voice-reference.json   # cuando existe una referencia
  metadata.json
```

En Windows, la misma estructura se guarda bajo `%LOCALAPPDATA%\ClassScribe\Classes\AAAA-MM-DD_HHMMSS_Materia-ID\`.

`live-transcript.txt` es UTF-8, legible con TextEdit o VS Code y se actualiza después de cada resultado ASR, pausa, reanudación y stop. JSON y journal son estado interno de recuperación; el usuario no necesita abrirlos.

“Exportar” permite elegir otro destino para TXT, Markdown o SRT. Al pulsar una entrada del historial se carga su texto dentro de ClassScribe; el botón de carpeta sigue abriendo Finder. El audio original nunca se borra automáticamente.

## Recuperar o reintentar una sesión

Al arrancar, ClassScribe escanea las carpetas aunque falte `metadata.json`. Reconoce WAV + TXT, estados interrumpidos y snapshots JSON antiguos. Una sesión incompleta aparece como **Sesión recuperable**:

1. Pulsa la sesión en el historial para cargar el mejor texto disponible.
2. Usa Copiar, Abrir TXT o Abrir carpeta aunque el procesamiento haya fallado.
3. Pulsa “Reintentar procesamiento”. Si `source.wav` es válido se reutiliza sin modificarlo; si el cierre dejó solamente un `source.raw` Float32 válido, ClassScribe reconstruye el WAV conservando el RAW y cualquier WAV inválido previo como evidencia. Si ya existe transcripción final completa, se reintenta solamente la identificación de voces.
4. Si solo existe JSON legacy, la app crea TXT/Markdown sin modificar ese JSON. Si el WAV es inválido, conserva el texto y deshabilita únicamente el reprocesamiento.

## Pruebas

Con Xcode completo:

```bash
swift test --package-path app/MeetingTranscriber -j 2
xcodebuild -scheme ClassScribe -destination 'platform=macOS' build
```

Con las Command Line Tools incompletas de esta Mac, usa temporalmente:

```bash
export SWIFTPM_CUSTOM_LIBS_DIR="$(./scripts/prepare_local_toolchain.sh)"
swift test --package-path .toolchain/ClassScribePackage -j 2 \
  -Xswiftc -resource-dir -Xswiftc "$PWD/.toolchain/usr/lib/swift"
```

Las pruebas cubren acumulación monotónica (incluidas 100 ventanas), ring buffer acotado, cursor y backoff en vivo, carga single-flight, inferencias serializadas, cancelación, journal/TXT, recuperación legacy y desde RAW sin borrar evidencia, archivos WAV válidos e inválidos, correcciones en vivo que sobreviven a nuevas ventanas ASR, preservación AppKit de caret/selección/viewport, seguimiento automático, composición IME, continuidad de párrafos, copia/exportación, fallos de ASR y diarización, timeout/terminación del helper, cambio de profesor y conservación de todos los hablantes. Las pruebas físicas de micrófono y audio de aplicación requieren permisos TCC e interacción con una fuente audible; no se simulan como éxitos en CI.

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

La suite cubre además compatibilidad de metadatos multilingües y sesiones heredadas. Los fixtures físicos/de modelos quedan omitidos salvo activación explícita porque requieren permisos, audio o descargas reales.

## Limitaciones conocidas del MVP

- La diarización y las tarjetas de varios hablantes se actualizan al detener la clase; durante la grabación se conserva y muestra el texto vivo, pero no se promete diarización verdaderamente streaming.
- La separación de voces, superposiciones y reconocimiento son de mejor esfuerzo. Los casos inseguros se conservan en Revisar.
- La primera carga de modelos puede tardar varios minutos y consumir memoria significativa; en Windows la descarga de Whisper es de aproximadamente 574 MB.
- Editar texto no cambia el audio ni los segmentos JSON. TXT/Markdown sí reflejan la edición; SRT conserva tiempos/segmentos finales y lo advierte.
- En esta máquina no hay Xcode completo. SwiftPM valida localmente y GitHub Actions ejecuta XCTest y builds Xcode Debug/Release.
- La suite XCTest heredada de `tools/audiotap` tampoco está disponible con estos Command Line Tools (`no such module XCTest`), aunque la biblioteca sí compila y enlaza dentro del target ClassScribe.
- Las pruebas físicas dependen de permisos macOS y de una fuente audible. Concédelos únicamente a ClassScribe cuando el sistema los solicite.

## Solución de problemas

- **El medidor no se mueve:** verifica la fuente seleccionada y el permiso de Micrófono o Audio del sistema. Detén; el texto ya guardado y cualquier audio parcial se conservan.
- **La transcripción tarda:** la primera carga de modelos puede demorar varios minutos. El WAV continúa grabándose.
- **Falló “Identificando hablantes”:** la transcripción completa ya fue guardada. Usa Copiar/Abrir TXT y luego Reintentar procesamiento.
- **Una sesión figura recuperable:** ábrela; el banner explica si puede reprocesarse o si solo puede recuperarse el texto.
- **Duda sobre el binario abierto:** coloca el cursor sobre el encabezado para consultar la procedencia del build y compárala con `git rev-parse HEAD`. `scripts/run_app.sh` imprime además PID y ruta exacta.

## GitHub

Los modelos, grabaciones, transcripciones, embeddings, logs, secretos y artefactos de build están ignorados. El CI automático valida macOS y Windows: usa revisiones fijas de Actions, dependencias Swift/NuGet bloqueadas, pruebas unitarias, builds Release y un smoke test del ejecutable Windows publicado. Las pruebas que requieren permisos, micrófono, audio real o interfaz gráfica quedan como pruebas físicas opt-in.

Para subir cambios posteriores:

```bash
git add -A
git commit -m "describe el cambio"
git push
```
