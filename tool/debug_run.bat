@echo off
rem Build and launch Karmashala in debug mode, for hands-on verification.
rem
rem Run it through the KarmashalaDebug scheduled task, never directly from WSL:
rem interop cannot traverse the plugin symlinks a Flutter Windows build needs.
rem `flutter run` stays alive, so the task stays running until the app is
rem closed; the VM service URI it prints is in %LOG%.
rem
rem A debug run is a PROBE by default (owner, 2026-10-06): it sets
rem KARMASHALA_DATA_DIR to build\debug-data and KARMASHALA_PROBE=1, so its
rem database, logs, IPC socket, MCP handshake, vault and server all live there,
rem and it leaves the agents' hooks, skills, autostart and relay alone
rem (PROJECT.md 23). The data folder is kept between runs.
rem
rem     tool\debug_run.bat -Live
rem
rem attaches to the REAL database and this machine's server instead, like a
rem second copy of the installed app. Only on purpose, and never beside the
rem installed app: it takes over the agents' hooks. path_provider resolves
rem the support directory through SHGetKnownFolderPath, so redirecting
rem %APPDATA% does not move it; KARMASHALA_DATA_DIR is the one thing that does
rem (core\paths\app_support_directory.dart). -Fresh is accepted and is the
rem default.
setlocal enabledelayedexpansion
rem The Flutter client is app\, beside this folder.
cd /d "%~dp0..\app"

set LIVE=
if /i "%~1"=="-Live" set LIVE=1
if /i "%~1"=="--live" set LIVE=1

set LOG=%USERPROFILE%\karmashala-debug.log
set DONE=%USERPROFILE%\karmashala-debug.done
set FLUTTER=%USERPROFILE%\flutter\bin\flutter.bat
del /q "%DONE%" 2>nul

set APPVER=
for /f "tokens=2" %%v in ('findstr /b "version:" pubspec.yaml') do set APPVER=%%v
echo === DEBUG RUN !APPVER! === > "%LOG%"

if not defined LIVE (
  set KARMASHALA_DATA_DIR=!CD!\build\debug-data
  set KARMASHALA_PROBE=1
  if not exist "!KARMASHALA_DATA_DIR!" mkdir "!KARMASHALA_DATA_DIR!"
  echo === PROBE DATA !KARMASHALA_DATA_DIR! === >> "%LOG%"
)

call "%FLUTTER%" run --debug -d windows --dart-define=KARMASHALA_VERSION=!APPVER! --dart-define=KARMASHALA_RELAY_URL=wss://kmrelay.popupbits.com >> "%LOG%" 2>&1
echo EXITED > "%DONE%"
exit /b 0
