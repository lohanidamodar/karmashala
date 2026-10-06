@echo off
rem Build and launch Karmashala in profile mode, for a profiling session.
rem
rem Run it through the KarmashalaProfile scheduled task, never directly from
rem WSL: interop cannot traverse the plugin symlinks a Flutter Windows build
rem needs. `flutter run` stays alive, so the task stays running until the app
rem is closed; the VM service URI it prints is in %LOG%.
setlocal enabledelayedexpansion
rem The Flutter client is app\, beside this folder.
cd /d "%~dp0..\app"

set LOG=%USERPROFILE%\karmashala-profile.log
set DONE=%USERPROFILE%\karmashala-profile.done
set FLUTTER=%USERPROFILE%\flutter\bin\flutter.bat
del /q "%DONE%" 2>nul

rem Always a probe (PROJECT.md section 23): a profile run is a second instance
rem beside the installed app, and without KARMASHALA_PROBE it would take over
rem that app's agent hooks. Data goes to build\profile-data unless the caller
rem already chose a KARMASHALA_DATA_DIR.
set KARMASHALA_PROBE=1
if not defined KARMASHALA_DATA_DIR set KARMASHALA_DATA_DIR=!CD!\build\profile-data
if not exist "!KARMASHALA_DATA_DIR!" mkdir "!KARMASHALA_DATA_DIR!"

set APPVER=
for /f "tokens=2" %%v in ('findstr /b "version:" pubspec.yaml') do set APPVER=%%v
echo === PROFILE RUN !APPVER! (probe, data !KARMASHALA_DATA_DIR!) === > "%LOG%"

call "%FLUTTER%" run --profile -d windows --dart-define=KARMASHALA_VERSION=!APPVER! --dart-define=KARMASHALA_RELAY_URL=wss://kmrelay.popupbits.com >> "%LOG%" 2>&1
echo EXITED > "%DONE%"
exit /b 0
