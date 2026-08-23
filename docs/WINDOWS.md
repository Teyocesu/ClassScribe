# ClassScribe para Windows

## Instalación rápida

1. Abre [GitHub Releases](https://github.com/Teyocesu/ClassScribe/releases/latest).
2. Descarga `ClassScribe-vX.Y.Z-windows-x64-setup.exe`.
3. Abre el archivo y sigue el asistente. No requiere permisos de administrador ni instalar .NET.
4. Inicia ClassScribe desde el menú Inicio.

Requiere Windows 11 x64, build 22000 o posterior. Hay también un ZIP portable para usar sin instalación.

El instalador actual no tiene firma Authenticode. Si SmartScreen aparece, comprueba primero el `.sha256` publicado junto al instalador y continúa solo si confías en la descarga. No desactives SmartScreen.

## Primera clase

1. Escribe la materia.
2. Selecciona **Español**, **English** o **Français**. La elección se aplica tanto al texto en vivo como a la retranscripción final.
3. Elige **Clase online** para capturar una aplicación y su árbol de procesos, o **Clase presencial** para usar un micrófono. ClassScribe nunca mezcla ambos automáticamente.
4. Agrega nombres propios, siglas o términos técnicos separados por comas.
5. Pulsa **Iniciar** y comprueba que el medidor se mueva.

La primera transcripción descarga Whisper large-v3-turbo cuantizado, aproximadamente 574 MB. La primera identificación de voces descarga además dos modelos más pequeños. Las descargas usan HTTPS, tamaño esperado y SHA-256 fijo; una descarga incompleta no se instala. Después, la app funciona localmente.

## Privacidad y recuperación

No hay cuenta, telemetría ni API remota. Las sesiones se guardan bajo:

```text
%LOCALAPPDATA%\ClassScribe\Classes\
```

Los modelos quedan en `%LOCALAPPDATA%\ClassScribe\Models\` y los registros de error locales en `%LOCALAPPDATA%\ClassScribe\Logs\`.

El audio se escribe primero como PCM recuperable y se convierte atómicamente a `source.wav` al detener. Si Windows, la fuente o la inferencia fallan, abre **Historial**, carga la sesión y usa **Reprocesar**. La transcripción completa se confirma en disco antes de iniciar la separación nativa de hablantes.

## Solución de problemas

- **No aparece una aplicación:** ábrela, espera a que tenga una ventana visible y pulsa **Actualizar**.
- **No llega audio de una clase online:** reproduce sonido dentro de la aplicación seleccionada. ClassScribe espera una muestra real antes de declarar que está grabando.
- **No llega audio del micrófono:** ve a **Configuración → Privacidad y seguridad → Micrófono** y permite el acceso para aplicaciones de escritorio.
- **La primera transcripción tarda:** mantén conexión y espacio libre mientras se descarga el modelo; el audio continúa guardándose.
- **Falló la identificación de hablantes:** el texto completo ya quedó guardado. Puedes editarlo, exportarlo o pulsar **Reprocesar**.
- **SmartScreen muestra una advertencia:** verifica el checksum y continúa solo si la descarga proviene de la Release esperada.

## Compilar desde código

Requisitos de desarrollo: Windows 11, SDK .NET `10.0.302`, PowerShell e Inno Setup 6 o posterior.

```powershell
git clone https://github.com/Teyocesu/ClassScribe.git
cd ClassScribe
./scripts/build_windows.ps1
```

El script usa `packages.lock.json`, analizadores con warnings como errores, pruebas unitarias, publicación autocontenida, smoke test, Inno Setup y checksums SHA-256. Los resultados quedan en `.build/windows/release/`.
