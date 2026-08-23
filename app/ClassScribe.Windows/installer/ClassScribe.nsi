!ifndef CLASSSCRIBE_VERSION
  !error "CLASSSCRIBE_VERSION is required"
!endif
!ifndef CLASSSCRIBE_PUBLISH_DIR
  !error "CLASSSCRIBE_PUBLISH_DIR is required"
!endif
!ifndef CLASSSCRIBE_OUTPUT_FILE
  !error "CLASSSCRIBE_OUTPUT_FILE is required"
!endif
!ifndef CLASSSCRIBE_LICENSE_FILE
  !error "CLASSSCRIBE_LICENSE_FILE is required"
!endif
!ifndef CLASSSCRIBE_ICON_FILE
  !error "CLASSSCRIBE_ICON_FILE is required"
!endif

Unicode true
RequestExecutionLevel user
SetCompressor /SOLID lzma
SetCompressorDictSize 16
CRCCheck on
SetOverwrite on
XPStyle on
ManifestDPIAware true

Name "ClassScribe ${CLASSSCRIBE_VERSION}"
Caption "ClassScribe ${CLASSSCRIBE_VERSION}"
BrandingText "ClassScribe"
OutFile "${CLASSSCRIBE_OUTPUT_FILE}"
InstallDir "$LOCALAPPDATA\Programs\ClassScribe"
Icon "${CLASSSCRIBE_ICON_FILE}"
UninstallIcon "${CLASSSCRIBE_ICON_FILE}"

VIProductVersion "${CLASSSCRIBE_VERSION}.0"
VIAddVersionKey /LANG=1033 "ProductName" "ClassScribe"
VIAddVersionKey /LANG=1033 "ProductVersion" "${CLASSSCRIBE_VERSION}"
VIAddVersionKey /LANG=1033 "FileVersion" "${CLASSSCRIBE_VERSION}"
VIAddVersionKey /LANG=1033 "FileDescription" "ClassScribe installer"
VIAddVersionKey /LANG=1033 "CompanyName" "ClassScribe contributors"
VIAddVersionKey /LANG=1033 "LegalCopyright" "Copyright (c) ClassScribe contributors"
VIAddVersionKey /LANG=1033 "OriginalFilename" "ClassScribe-v${CLASSSCRIBE_VERSION}-windows-x64-setup.exe"

!include "MUI2.nsh"

!define MUI_ABORTWARNING
!define MUI_ICON "${CLASSSCRIBE_ICON_FILE}"
!define MUI_UNICON "${CLASSSCRIBE_ICON_FILE}"
!define MUI_LANGDLL_REGISTRY_ROOT HKCU
!define MUI_LANGDLL_REGISTRY_KEY "Software\ClassScribe"
!define MUI_LANGDLL_REGISTRY_VALUENAME "InstallerLanguage"
!define MUI_STARTMENUPAGE_DEFAULTFOLDER "ClassScribe"
!define MUI_STARTMENUPAGE_REGISTRY_ROOT HKCU
!define MUI_STARTMENUPAGE_REGISTRY_KEY "Software\ClassScribe"
!define MUI_STARTMENUPAGE_REGISTRY_VALUENAME "StartMenuFolder"
!define MUI_FINISHPAGE_RUN "$INSTDIR\ClassScribe.exe"
!define MUI_FINISHPAGE_RUN_NOTCHECKED

Var StartMenuFolder

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${CLASSSCRIBE_LICENSE_FILE}"
!insertmacro MUI_PAGE_STARTMENU Application $StartMenuFolder
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_UNPAGE_FINISH

!insertmacro MUI_LANGUAGE "English"
!insertmacro MUI_LANGUAGE "Spanish"
!insertmacro MUI_LANGUAGE "French"

LangString RequiresWindows11 ${LANG_ENGLISH} "ClassScribe requires Windows 11 (build 22000 or newer)."
LangString RequiresWindows11 ${LANG_SPANISH} "ClassScribe requiere Windows 11 (compilación 22000 o posterior)."
LangString RequiresWindows11 ${LANG_FRENCH} "ClassScribe nécessite Windows 11 (version 22000 ou ultérieure)."
LangString RequiresX64 ${LANG_ENGLISH} "ClassScribe requires 64-bit Windows on an x64 (AMD64) processor."
LangString RequiresX64 ${LANG_SPANISH} "ClassScribe requiere Windows de 64 bits en un procesador x64 (AMD64)."
LangString RequiresX64 ${LANG_FRENCH} "ClassScribe nécessite Windows 64 bits sur un processeur x64 (AMD64)."
LangString UnsafeInstallDirectory ${LANG_ENGLISH} "ClassScribe can only be installed in its dedicated per-user folder."
LangString UnsafeInstallDirectory ${LANG_SPANISH} "ClassScribe solo puede instalarse en su carpeta dedicada por usuario."
LangString UnsafeInstallDirectory ${LANG_FRENCH} "ClassScribe ne peut être installé que dans son dossier dédié par utilisateur."
LangString UnsafeUninstallDirectory ${LANG_ENGLISH} "The ClassScribe installation folder could not be verified. No files were removed."
LangString UnsafeUninstallDirectory ${LANG_SPANISH} "No se pudo verificar la carpeta de instalación de ClassScribe. No se eliminó ningún archivo."
LangString UnsafeUninstallDirectory ${LANG_FRENCH} "Le dossier d'installation de ClassScribe n'a pas pu être vérifié. Aucun fichier n'a été supprimé."
LangString DesktopShortcut ${LANG_ENGLISH} "Desktop shortcut"
LangString DesktopShortcut ${LANG_SPANISH} "Acceso directo en el escritorio"
LangString DesktopShortcut ${LANG_FRENCH} "Raccourci sur le Bureau"
LangString DesktopShortcutDescription ${LANG_ENGLISH} "Create a ClassScribe shortcut on the desktop."
LangString DesktopShortcutDescription ${LANG_SPANISH} "Crear un acceso directo de ClassScribe en el escritorio."
LangString DesktopShortcutDescription ${LANG_FRENCH} "Créer un raccourci ClassScribe sur le Bureau."

Function .onInit
  !insertmacro MUI_LANGDLL_DISPLAY

  ReadEnvStr $0 "PROCESSOR_ARCHITEW6432"
  StrCmp $0 "AMD64" supported_architecture
  ReadEnvStr $0 "PROCESSOR_ARCHITECTURE"
  StrCmp $0 "AMD64" supported_architecture unsupported_architecture

  unsupported_architecture:
    MessageBox MB_OK|MB_ICONSTOP "$(RequiresX64)"
    Abort

  supported_architecture:
  ReadRegStr $1 HKLM "SOFTWARE\Microsoft\Windows NT\CurrentVersion" "CurrentBuildNumber"
  StrCmp $1 "" unsupported_windows
  IntCmp $1 22000 supported_windows unsupported_windows supported_windows

  unsupported_windows:
    MessageBox MB_OK|MB_ICONSTOP "$(RequiresWindows11)"
    Abort

  supported_windows:
FunctionEnd

Function un.onInit
  !insertmacro MUI_UNGETLANGUAGE
FunctionEnd

Section "ClassScribe" ApplicationSection
  SectionIn RO
  SetShellVarContext current
  StrCmp "$INSTDIR" "$LOCALAPPDATA\Programs\ClassScribe" valid_install_directory
    MessageBox MB_OK|MB_ICONSTOP "$(UnsafeInstallDirectory)"
    Abort

  valid_install_directory:
  CreateDirectory "$INSTDIR"
  SetOutPath "$INSTDIR"
  ClearErrors
  FileOpen $0 "$INSTDIR\.classscribe-install-root" w
  IfErrors invalid_install_directory
  FileWrite $0 "ClassScribe:B00AF29B-447A-49DD-8135-D5E61C718E25"
  FileClose $0
  File /r "${CLASSSCRIBE_PUBLISH_DIR}\*"

  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKCU "Software\ClassScribe" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ClassScribe" "DisplayName" "ClassScribe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ClassScribe" "DisplayVersion" "${CLASSSCRIBE_VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ClassScribe" "Publisher" "ClassScribe contributors"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ClassScribe" "DisplayIcon" "$INSTDIR\ClassScribe.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ClassScribe" "UninstallString" '$\"$INSTDIR\Uninstall.exe$\"'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ClassScribe" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ClassScribe" "NoRepair" 1

  !insertmacro MUI_STARTMENU_WRITE_BEGIN Application
    CreateDirectory "$SMPROGRAMS\$StartMenuFolder"
    CreateShortcut "$SMPROGRAMS\$StartMenuFolder\ClassScribe.lnk" "$INSTDIR\ClassScribe.exe"
    CreateShortcut "$SMPROGRAMS\$StartMenuFolder\Uninstall ClassScribe.lnk" "$INSTDIR\Uninstall.exe"
  !insertmacro MUI_STARTMENU_WRITE_END
  Goto install_directory_verified

  invalid_install_directory:
    MessageBox MB_OK|MB_ICONSTOP "$(UnsafeInstallDirectory)"
    Abort

  install_directory_verified:
SectionEnd

Section /o "$(DesktopShortcut)" DesktopSection
  SetShellVarContext current
  CreateShortcut "$DESKTOP\ClassScribe.lnk" "$INSTDIR\ClassScribe.exe"
SectionEnd

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${DesktopSection} "$(DesktopShortcutDescription)"
!insertmacro MUI_FUNCTION_DESCRIPTION_END

Section "Uninstall"
  SetShellVarContext current
  StrCmp "$INSTDIR" "$LOCALAPPDATA\Programs\ClassScribe" verify_install_marker unsafe_uninstall_directory

  verify_install_marker:
  ClearErrors
  FileOpen $0 "$INSTDIR\.classscribe-install-root" r
  IfErrors unsafe_uninstall_directory
  FileRead $0 $1
  FileClose $0
  StrCmp $1 "ClassScribe:B00AF29B-447A-49DD-8135-D5E61C718E25" verified_uninstall_directory unsafe_uninstall_directory

  unsafe_uninstall_directory:
    MessageBox MB_OK|MB_ICONSTOP "$(UnsafeUninstallDirectory)"
    SetErrorLevel 2
    Quit

  verified_uninstall_directory:

  Delete "$DESKTOP\ClassScribe.lnk"
  !insertmacro MUI_STARTMENU_GETFOLDER Application $StartMenuFolder
  Delete "$SMPROGRAMS\$StartMenuFolder\ClassScribe.lnk"
  Delete "$SMPROGRAMS\$StartMenuFolder\Uninstall ClassScribe.lnk"
  RMDir "$SMPROGRAMS\$StartMenuFolder"

  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\ClassScribe"
  DeleteRegKey HKCU "Software\ClassScribe"
  RMDir /r "$INSTDIR"
SectionEnd
