@echo off
rem Build and launch Karmashala in debug mode, for hands-on verification.
rem
rem Run it through the KarmashalaDebug scheduled task, never directly from WSL:
rem interop cannot traverse the plugin symlinks a Flutter Windows build needs.
rem `flutter run` stays alive, so the task stays running until the app is
rem closed; the VM service URI it prints is in %LOG%.
rem
rem A debug run uses the REAL database. path_provider resolves the support
rem directory through SHGetKnownFolderPath, so redirecting %APPDATA% does not
rem move it — anything done in this instance is done to the live data.
rem
rem     tool\debug_run.bat -Fresh        (or --fresh)
rem
rem is the way out: it sets KARMASHALA_DATA_DIR, which is the one thing that
rem does move it (core\paths\app_support_directory.dart), to build\debug-data.
rem Database, logs, IPC socket, MCP handshake and vault all go there and the
rem live data is never opened. It also sets KARMASHALA_PROBE=1, so the instance
rem leaves the agents' hooks, skills, autostart and relay alone (PROJECT.md 23).
rem The default is unchanged, because a debug run is usually meant to see the
rem real workspace — and is therefore never to be run beside the installed app.
setlocal enabledelayedexpansion
rem The Flutter client is app\, beside this folder.
cd /d "%~dp0..\app"

set FRESH=
if /i "%~1"=="-Fresh" set FRESH=1
if /i "%~1"=="--fresh" set FRESH=1

set LOG=%USERPROFILE%\karmashala-debug.log
set DONE=%USERPROFILE%\karmashala-debug.done
set FLUTTER=%USERPROFILE%\flutter\bin\flutter.bat
del /q "%DONE%" 2>nul

set APPVER=
for /f "tokens=2" %%v in ('findstr /b "version:" pubspec.yaml') do set APPVER=%%v
echo === DEBUG RUN !APPVER! === > "%LOG%"

if defined FRESH (
  set KARMASHALA_DATA_DIR=!CD!\build\debug-data
  set KARMASHALA_PROBE=1
  if not exist "!KARMASHALA_DATA_DIR!" mkdir "!KARMASHALA_DATA_DIR!"
  echo === FRESH DATA !KARMASHALA_DATA_DIR! === >> "%LOG%"
)

call "%FLUTTER%" run --debug -d windows --dart-define=KARMASHALA_VERSION=!APPVER! --dart-define=KARMASHALA_RELAY_URL=wss://relay.popupbits.com >> "%LOG%" 2>&1
echo EXITED > "%DONE%"
exit /b 0
