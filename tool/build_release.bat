@echo off
rem Karmashala's release recipe, versioned with the app it builds.
rem
rem This lived at C:\Users\dlohani\karmashala-build.bat until 2026-09-03, which
rem meant how the app is packaged was not reviewed, not in history, and did not
rem travel to another machine. That is how `karmashala_mcp.exe` — a component
rem the app needs to reach its own MCP surface from inside WSL — went unbuilt
rem without anyone noticing. The machine's copy is now a thin wrapper that calls
rem this file, so the scheduled task keeps working and the recipe is here.
rem
rem Run it through the KarmashalaBuild scheduled task, never directly from WSL:
rem interop cannot traverse the plugin symlinks a Flutter Windows build needs.
setlocal enabledelayedexpansion
cd /d "%~dp0.."

set LOG=%USERPROFILE%\karmashala-build.log
set DONE=%USERPROFILE%\karmashala-build.done
set FLUTTER=%USERPROFILE%\flutter\bin\flutter.bat
set DARTEXE=%USERPROFILE%\flutter\bin\cache\dart-sdk\bin\dart.exe
set RELEASE=build\windows\x64\runner\Release
del /q "%DONE%" 2>nul

rem Read the version straight out of pubspec.yaml so it cannot drift from what
rem was built. "version: 1.2.0+12" -> APPVER=1.2.0+12, APPVERSHORT=1.2.0.
rem If this fails APPVER stays empty and the app logs "version not recorded",
rem which is the honest outcome rather than a stale number.
set APPVER=
for /f "tokens=2" %%v in ('findstr /b "version:" pubspec.yaml') do set APPVER=%%v
for /f "delims=+" %%a in ("!APPVER!") do set APPVERSHORT=%%a
if "!APPVERSHORT!"=="" set APPVERSHORT=1.2.0
echo === BUILDING !APPVER! === > "%LOG%"

echo === WINDOWS RELEASE === >> "%LOG%"
call "%FLUTTER%" build windows --release --dart-define=KARMASHALA_VERSION=!APPVER! >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

rem The MCP stdio bridge. A WSL session's MCP entry names this exe rather than a
rem URL on the WSL switch address, because an agent inside a distribution cannot
rem reach the host across that switch on this machine. It is compiled into the
rem Release directory, which the installer copies wholesale (karmashala.iss's
rem `Source: {#SourceDir}\*`), so no installer change is needed. Without it a WSL
rem session falls back to the switch URL and gets no tools.
echo === MCP BRIDGE === >> "%LOG%"
call "%FLUTTER%" pub get --directory mcp_bridge >> "%LOG%" 2>&1
if errorlevel 1 goto :fail
"%DARTEXE%" compile exe mcp_bridge\bin\karmashala_mcp.dart -o "%RELEASE%\karmashala_mcp.exe" >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

echo === INSTALLER === >> "%LOG%"
"%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe" /DMyAppVersion=!APPVERSHORT! windows\installer\karmashala.iss >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

echo === ANDROID COMPANION APK === >> "%LOG%"
call "%FLUTTER%" build apk --release --dart-define=KARMASHALA_MODE=companion --dart-define=KARMASHALA_VERSION=!APPVER! >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

echo OK > "%DONE%"
exit /b 0
:fail
echo FAIL > "%DONE%"
exit /b 1
