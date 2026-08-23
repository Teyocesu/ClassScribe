# Distribución de ClassScribe

ClassScribe se distribuye desde los assets de una GitHub Release del repositorio privado. Quien tenga acceso puede descargar un instalador y compartir ese archivo sin entregar el repositorio ni los datos locales de las clases.

## Assets oficiales

Cada versión `X.Y.Z` publica exactamente estos seis archivos:

```text
ClassScribe-vX.Y.Z-arm64.dmg
ClassScribe-vX.Y.Z-arm64.dmg.sha256
ClassScribe-vX.Y.Z-windows-x64-setup.exe
ClassScribe-vX.Y.Z-windows-x64-setup.exe.sha256
ClassScribe-vX.Y.Z-windows-x64-portable.zip
ClassScribe-vX.Y.Z-windows-x64-portable.zip.sha256
```

El instalador de Windows es autocontenido y por usuario: no necesita privilegios de administrador ni una instalación previa de .NET. El ZIP portable contiene la misma aplicación sin asistente. El DMG contiene `ClassScribe.app` y el helper de diarización.

Los modelos no se incluyen en los paquetes. La aplicación los descarga al primer uso y, en Windows, valida tamaño y SHA-256 antes de cargarlos.

## Crear una release oficial

`VERSION` es la única fuente de verdad y debe usar `X.Y.Z`. El tag debe ser exactamente `v` seguido de ese valor y apuntar a un commit ya presente en `origin/main`.

```bash
# Después de actualizar VERSION y validar main:
git add -A
git commit -m "release: ClassScribe v1.0.0"
git push origin main
git tag -a v1.0.0 -m "ClassScribe v1.0.0"
git push origin v1.0.0
```

El tag inicia **Publish ClassScribe release** con dos builds independientes:

- macOS 14.2+ / Apple Silicon: compila y prueba Swift, arma el bundle, verifica arquitectura, dependencias, firma ad-hoc y DMG.
- Windows 11 / x64: restaura NuGet en modo bloqueado, compila con analizadores, ejecuta pruebas, publica autocontenido, hace un smoke test y crea el instalador con Inno Setup y el ZIP portable.

El job final descarga ambos artifacts, verifica los tres checksums y el conjunto exacto de seis archivos. Crea primero un borrador, vuelve a comprobar sus assets y solo entonces publica la Release. Se niega a reemplazar una Release existente.

## Verificar una descarga

macOS:

```bash
shasum -a 256 -c ClassScribe-vX.Y.Z-arm64.dmg.sha256
```

Windows PowerShell:

```powershell
$expected = (Get-Content .\ClassScribe-vX.Y.Z-windows-x64-setup.exe.sha256).Split(' ')[0]
$actual = (Get-FileHash .\ClassScribe-vX.Y.Z-windows-x64-setup.exe -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $expected) { throw 'El checksum no coincide' }
```

## Instalación

### Windows 11 x64

1. Descarga el archivo `windows-x64-setup.exe` y su `.sha256`.
2. Comprueba el checksum.
3. Abre el instalador y sigue el asistente. Se instala bajo el perfil del usuario y crea un acceso del menú Inicio; el acceso de escritorio es opcional.
4. Si SmartScreen aparece, comprueba que el hash coincida y usa **Más información → Ejecutar de todas formas** únicamente si confías en el origen.
5. Elige español, inglés o francés antes de iniciar la clase y espera la descarga inicial del modelo.

La build no tiene todavía firma Authenticode, porque el repositorio no dispone de un certificado de firma de código. No desactives SmartScreen globalmente.

### macOS 14.2+ / Apple Silicon

1. Descarga el DMG y su `.sha256`.
2. Comprueba el checksum, abre el DMG y arrastra ClassScribe a Aplicaciones.
3. Si Gatekeeper bloquea la primera apertura, usa **Abrir** desde el menú contextual y confirma solo si confías en el archivo.
4. Concede únicamente los permisos de audio que corresponden a la fuente elegida.

La build está firmada ad-hoc y no está notarizada. No desactives Gatekeeper ni elimines globalmente la cuarentena.

## Build manual de Windows

En Windows 11 instala el SDK .NET `10.0.302` e Inno Setup 6 o posterior, clona el repositorio y ejecuta:

```powershell
./scripts/build_windows.ps1
```

Los archivos resultantes quedan en `.build/windows/release/`. Para omitir solo el instalador durante desarrollo:

```powershell
./scripts/build_windows.ps1 -SkipInstaller
```

Si el `dotnet publish` autocontenido se generó desde macOS o Linux, el mismo
directorio puede empaquetarse con NSIS 3 sin ejecutar el binario Windows:

```bash
./scripts/package_windows_nsis.sh \
  --publish-dir=/ruta/al/publish/win-x64 \
  --makensis=/ruta/a/makensis
```

El empaquetador aplica las mismas comprobaciones de PE, runtimes nativos y
ausencia de símbolos, excluye arquitecturas no utilizadas y produce el mismo
conjunto de instalador, ZIP portable y checksums. La prueba de arranque del
ejecutable debe hacerse aparte en Windows; el pipeline oficial la realiza antes
de empaquetar.

## Build ad-hoc desde Actions

Desde **Actions → Publish ClassScribe release → Run workflow**, elige un tag existente. Una ejecución manual produce artifacts privados durante siete días, pero nunca crea ni modifica una GitHub Release.

Si un job falla después de crear el borrador de una Release, el borrador permanece privado para inspección. Elimínalo manualmente solo después de entender la causa; una reejecución se negará a sobrescribirlo.

## Firma comercial futura

La infraestructura local de macOS admite `Developer ID` y notarización mediante `scripts/build_release.sh`. Windows puede incorporar Authenticode cuando exista un certificado o una cuenta de Trusted Signing. Hasta entonces, los checksums y el pipeline reproducible protegen la integridad, pero no sustituyen una identidad de editor reconocida por el sistema operativo.
