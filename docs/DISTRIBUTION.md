# Distribución de ClassScribe para macOS

ClassScribe se distribuye desde los assets de una GitHub Release del repositorio privado. La privacidad del repositorio no impide que el propietario descargue el DMG y lo comparta manualmente: quienes reciben el archivo no necesitan acceso a GitHub, al código ni al repositorio.

## Crear una release oficial

`VERSION` es la única fuente de verdad. La versión debe tener el formato `X.Y.Z`; el script la copia tanto a `CFBundleShortVersionString` como a `CFBundleVersion` de la app. El tag debe ser exactamente `v` seguido de ese valor.

```bash
# Edita VERSION, por ejemplo: 1.0.0
git add VERSION
git commit -m "chore: prepare v1.0.0"
git push origin main

git tag v1.0.0
git push origin v1.0.0
```

El tag inicia **Publish ClassScribe release**. El commit etiquetado debe estar ya integrado en `origin/main`. La release se construye siempre con firma **ad-hoc**: no requiere cuenta Apple Developer, certificado, Developer ID ni notarización. La Release se mantiene como borrador hasta que ambos assets finales estén presentes y verificados.

Al terminar, en **GitHub → Releases → v1.0.0** descarga:

```text
ClassScribe-v1.0.0-arm64.dmg
ClassScribe-v1.0.0-arm64.dmg.sha256
```

Puedes comprobar el archivo antes de enviarlo:

```bash
shasum -a 256 ClassScribe-v1.0.0-arm64.dmg
cat ClassScribe-v1.0.0-arm64.dmg.sha256
```

El DMG contiene únicamente `ClassScribe.app` y el enlace `Applications → /Applications`. Incluye el binario `ClassScribeDiarizer` en `ClassScribe.app/Contents/Helpers/`, donde la app lo busca. Los modelos de FluidAudio no se empaquetan: se descargan al primer uso según el diseño de la aplicación.

Si una ejecución falla después de crear el borrador de la Release, el borrador queda privado para inspección y una reejecución se negará a reemplazarlo. Elimina manualmente ese borrador solo después de comprobar la causa y vuelve a ejecutar el workflow; nunca se publica automáticamente una Release incompleta.

## Instalación para quien recibe el DMG

La build ad-hoc puede mostrar una advertencia de Gatekeeper. No desactives Gatekeeper ni ejecutes comandos para eliminar la cuarentena. Si confías en quien te envió el archivo:

1. Abre `ClassScribe-vX.Y.Z-arm64.dmg`.
2. Arrastra `ClassScribe.app` a `Applications`.
3. Si macOS bloquea la primera apertura, haz clic con control en `ClassScribe.app`, selecciona **Abrir** y confirma el diálogo de macOS.
4. Acepta los permisos de macOS que solicite según el modo de captura.
5. Espera la descarga inicial de modelos cuando corresponda.

No necesita Swift, Xcode, Homebrew, Git ni una copia del repositorio. ClassScribe requiere Apple Silicon y macOS 14.2 o posterior.

## Build de prueba manual

Desde **Actions → Publish ClassScribe release → Run workflow**, elige un tag existente. Las ejecuciones manuales generan el mismo DMG ad-hoc verificado como un artifact privado de siete días y no tienen un camino que cree una GitHub Release. El tag debe coincidir con `VERSION` y apuntar a un commit de `origin/main`.

## Opción futura: Developer ID y notarización local

Developer ID y notarización no forman parte del pipeline de tags actual. La infraestructura local se conserva para una futura vía de distribución explícita, sin afectar el flujo ad-hoc ni requerir secrets en GitHub Actions. Si se habilita esa vía, importa el certificado en tu keychain y usa un perfil de `notarytool` creado por ti:

```bash
DEVELOPER_ID='<SHA-1 de Developer ID Application>' \
./scripts/build_release.sh --signing-mode=developer-id --notarize \
  --notary-profile classscribe-notary
```

## Qué verifica el pipeline

Antes de publicar, el workflow resuelve dependencias, compila y prueba SwiftPM y el empaquetador verifica el bundle: firma estricta ad-hoc, arquitectura `arm64`, helper incluido, referencias dinámicas locales, ausencia de código fuente/credenciales y montaje del DMG. Después descarga el mismo artifact en el job de publicación, comprueba su SHA-256, crea un borrador, verifica que contenga exactamente los dos assets esperados y solo entonces lo publica.

Los casks heredados bajo `Casks/` pertenecen a la distribución histórica de Meeting Transcriber y no son parte de este flujo: Homebrew no puede descargar de forma transparente assets de un repositorio privado. GitHub Releases es el único canal de distribución implementado para ClassScribe.
