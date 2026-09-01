; Inno Setup script for the Karmashala desktop app (Windows installer).
;
; Build locally:
;   flutter build windows --release
;   "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" /DMyAppVersion=0.1.0 windows\installer\karmashala.iss
;
; The release workflow passes the version from the git tag. Output goes to
; windows/installer/output/Karmashala-Setup-<version>.exe.

#define MyAppName "Karmashala"
#define MyAppPublisher "Karmashala"
#define MyAppURL "https://github.com/lohanidamodar/karmashala"
#define MyAppExeName "karmashala.exe"

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif

; Folder holding the `flutter build windows --release` output (the .exe, DLLs
; and the data/ bundle). Overridable from the command line for CI.
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif

[Setup]
; A fixed AppId keeps upgrades/uninstall stable across versions.
AppId={{7B3E1D42-8C5A-4F19-A6D3-2E8F0B9C4A71}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#MyAppExeName}
OutputDir=output
OutputBaseFilename=Karmashala-Setup-{#MyAppVersion}
SetupIconFile=..\..\assets\tray_icon.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
; --- Agents inside WSL -------------------------------------------------------
; WSL2 reaches the host across a Hyper-V virtual switch, and Windows governs
; that traffic with a SEPARATE firewall whose default inbound action is Block.
; That is why a hook posting from a distribution failed on every prompt with
; `curl: (52) Empty reply from server` while the identical request from Windows
; got a clean 401 — nothing was wrong with the server, and no ordinary firewall
; rule could have fixed it.
;
; Hyper-V rules name ports, never programs, so the app asks for one stable port
; (preferredControlPort) and this names exactly that port. Removed first so
; reinstalling leaves one rule rather than a pile. Wrapped so that a Windows
; without this cmdlet (pre-22H2) still installs cleanly — WSL sessions simply
; keep the degraded behaviour they already had.
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -Command ""try {{ Remove-NetFirewallHyperVRule -Name 'Chitragupta-WSL' -ErrorAction SilentlyContinue } catch {{ }; try {{ Remove-NetFirewallHyperVRule -Name 'Karmashala-WSL' -ErrorAction SilentlyContinue } catch {{ }; try {{ New-NetFirewallHyperVRule -Name 'Karmashala-WSL' -DisplayName 'Karmashala (agents in WSL)' -Direction Inbound -Action Allow -VMCreatorId '{{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -Protocol TCP -LocalPorts 47821 -ErrorAction Stop } catch {{ }"""; Flags: runhidden waituntilterminated; StatusMsg: "Allowing agents in WSL to reach Karmashala..."

; --- The phone ---------------------------------------------------------------
; The companion relay listens for a phone on the LAN, and the app logged
; `netsh refused the firewall rule (no admin?)` on every launch because it
; cannot add this itself. Program-scoped, so it covers the relay whatever port
; it lands on, and LocalSubnet-scoped, so it opens nothing beyond this network.
; The old app is uninstalled and its uninstaller will never run again, so
; its rules are ours to remove or they outlive both apps, pointing at an
; executable that no longer exists.
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Chitragupta"""; Flags: runhidden waituntilterminated
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Karmashala"""; Flags: runhidden waituntilterminated
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""Karmashala"" dir=in action=allow program=""{app}\{#MyAppExeName}"" enable=yes profile=any protocol=tcp remoteip=LocalSubnet"; Flags: runhidden waituntilterminated; StatusMsg: "Allowing your phone to reach Karmashala..."

Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Ours to remove: rules naming an executable and a port that no longer exist
; are exactly the litter an uninstall is for.
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -Command ""try {{ Remove-NetFirewallHyperVRule -Name 'Karmashala-WSL' -ErrorAction SilentlyContinue } catch {{ }"""; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Karmashala"""; Flags: runhidden
