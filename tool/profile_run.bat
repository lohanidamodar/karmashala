@echo off
rem Build and launch Karmashala in profile mode, for a profiling session.
rem
rem Run it through the KarmashalaProfile scheduled task, never directly from
rem WSL: interop cannot traverse the plugin symlinks a Flutter Windows build
rem needs. `flutter run` stays alive, so the task stays running until the app
rem is closed; the VM service URI it prints is in %LOG%.
setlocal enabledelayedexpansion
cd /d "%~dp0.."

set LOG=%USERPROFILE%\karmashala-profile.log
set DONE=%USERPROFILE%\karmashala-profile.done
set FLUTTER=%USERPROFILE%\flutter\bin\flutter.bat
del /q "%DONE%" 2>nul

set APPVER=
for /f "tokens=2" %%v in ('findstr /b "version:" pubspec.yaml') do set APPVER=%%v
echo === PROFILE RUN !APPVER! === > "%LOG%"

call "%FLUTTER%" run --profile -d windows --dart-define=KARMASHALA_VERSION=!APPVER! >> "%LOG%" 2>&1
echo EXITED > "%DONE%"
exit /b 0
