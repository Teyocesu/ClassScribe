#define AppVersion GetEnv("CLASSSCRIBE_VERSION")
#define PublishDirectory GetEnv("CLASSSCRIBE_PUBLISH_DIR")
#define ReleaseDirectory GetEnv("CLASSSCRIBE_RELEASE_DIR")
#define InstallerName GetEnv("CLASSSCRIBE_INSTALLER_NAME")

#if AppVersion == ""
  #error CLASSSCRIBE_VERSION is required
#endif
#if PublishDirectory == ""
  #error CLASSSCRIBE_PUBLISH_DIR is required
#endif
#if ReleaseDirectory == ""
  #error CLASSSCRIBE_RELEASE_DIR is required
#endif
#if InstallerName == ""
  #error CLASSSCRIBE_INSTALLER_NAME is required
#endif

[Setup]
AppId={{B00AF29B-447A-49DD-8135-D5E61C718E25}
AppName=ClassScribe
AppVersion={#AppVersion}
AppVerName=ClassScribe {#AppVersion}
AppPublisher=ClassScribe
AppCopyright=Copyright (c) 2025 pasrom and ClassScribe contributors
DefaultDirName={localappdata}\Programs\ClassScribe
DefaultGroupName=ClassScribe
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
MinVersion=10.0.22000
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#ReleaseDirectory}
OutputBaseFilename={#InstallerName}
SetupIconFile=..\src\ClassScribe.Windows\Assets\ClassScribe.ico
UninstallDisplayIcon={app}\ClassScribe.exe
LicenseFile=..\..\..\LICENSE
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
SetupLogging=yes
CloseApplications=yes
RestartApplications=no
ChangesAssociations=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "french"; MessagesFile: "compiler:Languages\French.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#PublishDirectory}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\ClassScribe"; Filename: "{app}\ClassScribe.exe"
Name: "{autodesktop}\ClassScribe"; Filename: "{app}\ClassScribe.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\ClassScribe.exe"; Description: "{cm:LaunchProgram,ClassScribe}"; Flags: nowait postinstall skipifsilent
