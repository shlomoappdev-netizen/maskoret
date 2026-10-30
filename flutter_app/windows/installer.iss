; Windows installer for מחשבון שכר (Inno Setup 6). Built by GitHub Actions after `flutter build windows`:
;   iscc /DAppVersion=4.2.0 /DAppBuild=36 windows\installer.iss
; Installs for the current user (no administrator prompt) into %LOCALAPPDATA%\Programs\Maskoret, adds Start-menu and
; desktop shortcuts and an entry in "Apps" for uninstalling. The app updates itself by running a newer installer
; silently (/VERYSILENT); [Run] opens the app again afterwards.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef AppBuild
  #define AppBuild "0"
#endif

[Setup]
AppId={{6F1C2A57-3B8E-4C1D-9E5A-7D2B4F8A9C31}
AppName=מחשבון שכר
AppVersion={#AppVersion}
AppVerName=מחשבון שכר {#AppVersion}
VersionInfoVersion={#AppVersion}.{#AppBuild}
AppPublisher=Shlomo David
AppPublisherURL=https://maskoret.vercel.app
DefaultDirName={localappdata}\Programs\Maskoret
DefaultGroupName=מחשבון שכר
DisableProgramGroupPage=yes
DisableDirPage=yes
DisableReadyPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\build
OutputBaseFilename=maskoret-windows-setup
SetupIconFile=runner\resources\app_icon.ico
UninstallDisplayIcon={app}\maskoret.exe
UninstallDisplayName=מחשבון שכר
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=force
RestartApplications=no

[Languages]
Name: "he"; MessagesFile: "compiler:Languages\Hebrew.isl"

[Tasks]
Name: "desktopicon"; Description: "קיצור דרך בשולחן העבודה"; GroupDescription: "קיצורי דרך:"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; Files of an older version that the new one no longer ships.
Type: filesandordirs; Name: "{app}\data"

[Icons]
Name: "{autoprograms}\מחשבון שכר"; Filename: "{app}\maskoret.exe"
Name: "{autodesktop}\מחשבון שכר"; Filename: "{app}\maskoret.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\maskoret.exe"; Description: "פתח את מחשבון שכר"; Flags: nowait postinstall
