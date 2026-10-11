#ifndef AppVersion
  #error Run tool/build_windows_installer.ps1 to supply the release configuration.
#endif

[Setup]
AppId={{C112F8D4-E998-4F62-A6D6-D52A2C661C29}
AppName=SmartReserve
AppVersion={#AppVersion}
AppPublisher=SmartReserve
VersionInfoVersion={#AppFileVersion}
VersionInfoDescription=SmartReserve Setup
DefaultDirName={localappdata}\Programs\SmartReserve
DefaultGroupName=SmartReserve
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=SmartReserve-Setup
SetupIconFile={#AppIcon}
UninstallDisplayIcon={app}\smartreserve.exe
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\SmartReserve"; Filename: "{app}\smartreserve.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\SmartReserve"; Filename: "{app}\smartreserve.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\smartreserve.exe"; WorkingDir: "{app}"; Description: "Launch SmartReserve"; Flags: nowait postinstall skipifsilent
