# Plan de implementación de ClassScribe

Fecha: 2026-08-06

## Entorno comprobado

- macOS 15.3.2 (24D81), arquitectura arm64.
- 8 GiB de memoria.
- SDK de macOS 15.5 en Command Line Tools.
- Swift 6.1.2.
- `xcodebuild` no está disponible: no hay una instalación completa de Xcode activa.
- GitHub CLI está autenticado como `Teyocesu`.

El deployment target es macOS 14 porque `CATapDescription`, usado para aislar el audio de una sola aplicación, requiere macOS 14.2 o posterior. La máquina supera ese requisito.

## Decisión: adaptar Meeting Transcriber

ClassScribe deriva de `pasrom/meeting-transcriber` (MIT, copyright 2025 pasrom). Se conserva el historial Git, `LICENSE` y la atribución. Adaptar esta base es objetivamente más estable que comenzar de cero porque ya aporta:

- captura Core Audio por PID y árbol de procesos con `CATapDescription`;
- captura de micrófono a WAV y medidor dBFS;
- entrega de búferes vivos a 16 kHz;
- Parakeet TDT v3 multilingüe y ventanas deslizantes;
- diarización local FluidAudio y embeddings WeSpeaker;
- recuperación y validación de WAV probadas.

El target anterior se reemplaza por `ClassScribe`. Los generadores Claude/OpenAI, servidores RPC, detección automática de reuniones, resúmenes y proveedores externos permanecen únicamente en el historial/código de referencia de upstream y están excluidos del target: no se compilan ni son accesibles desde el producto.

## Arquitectura objetivo

1. SwiftUI (`ClassScribeApp` y `ContentView`) presenta un único flujo manual.
2. `CaptureController` implementa exactamente dos rutas mutuamente excluyentes:
   - Online: AudioTapLib sobre la aplicación elegida, sin micrófono.
   - Presencial: AudioTapLib `MicCaptureHandler`, sin audio interno.
3. `LiveAudioBufferStore` conserva audio vivo a 16 kHz para ventanas de 7 s con 1,5 s de solapamiento.
4. `ParakeetService` usa FluidAudio y español explícito. `OverlapDeduplicator` estabiliza texto sin repetir la zona solapada.
5. `FinalProcessor` retranscribe el WAV completo, ejecuta diarización y asigna hablantes por solapamiento temporal.
6. `SessionStore` escribe audio, JSON, TXT, Markdown y SRT bajo Application Support/ClassScribe/Classes.
7. La selección del profesor filtra de forma no destructiva; baja confianza y solapamientos se conservan en `Revisar`.
8. Los embeddings se guardan localmente por sesión y como referencia reutilizable de la materia.

## Verificación realizada

- Build debug y release arm64 con SwiftPM: correctos.
- Bundle `.app` firmado ad hoc, `Info.plist` válido y lanzamiento estable: correctos.
- Suite lógica: 7/7 pruebas aprobadas.
- Parakeet TDT v3 sobre voz sintética conocida en español: aprobado; primera ejecución 388 s, incluyendo descarga y compilación inicial de Core ML.
- Diarización sobre un fixture de 49,5 s con dos voces sintéticas: aprobado; detectó dos centroides/etiquetas.
- CATap y micrófono tienen pruebas físicas repetibles, pero TCC no concedió permisos al host de tests en esta sesión. No se marcan como aprobadas; el WAV real de ambas rutas debe verificarse tras aceptar los diálogos desde ClassScribe.
- La biblioteca AudioTap compila dentro de ClassScribe. Su suite heredada usa XCTest y no puede compilarse con esta instalación parcial de Command Line Tools (`no such module XCTest`); requiere Xcode completo.
- `xcodebuild` queda bloqueado hasta instalar/seleccionar Xcode completo; no se afirmará lo contrario.
