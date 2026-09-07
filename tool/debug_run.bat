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
setlocal enabledelayedexpansion
cd /d "%~dp0.."

set LOG=%USERPROFILE%\karmashala-debug.log
set DONE=%USERPROFILE%\karmashala-debug.done
set FLUTTER=%USERPROFILE%\flutter\bin\flutter.bat
del /q "%DONE%" 2>nul

set APPVER=
for /f "tokens=2" %%v in ('findstr /b "version:" pubspec.yaml') do set APPVER=%%v
echo === DEBUG RUN !APPVER! === > "%LOG%"

call "%FLUTTER%" run --debug -d windows --dart-define=KARMASHALA_VERSION=!APPVER! >> "%LOG%" 2>&1
echo EXITED > "%DONE%"
exit /b 0
