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

rem The session host, cross-compiled for the machines it gets deployed to.
rem Measured 2026-09-08 on Dart 3.13.2 (windows_x64): `compile exe` accepts
rem --target-os=linux for arm, arm64, riscv64 and x64 and produces glibc-linked
rem ELF binaries; the x64 one ran unmodified inside WSL. It refuses macOS
rem outright ("Unsupported target platform macos_arm64"), so macOS hosts fall
rem back to tmux and HostDeployer says so. musl hosts are out of scope for the
rem same reason: these are glibc-linked.
rem
rem They land in the Release directory beside karmashala_mcp.exe, which the
rem installer copies wholesale, so no installer change is needed. The version
rem is in the filename because HostDeployer compares it against what the remote
rem binary reports rather than trusting the name.
echo === SESSION HOST (linux x64, arm64, and this machine) === >> "%LOG%"
call "%FLUTTER%" pub get --directory host >> "%LOG%" 2>&1
if errorlevel 1 goto :fail
"%DARTEXE%" compile exe host\bin\karmashala_host.dart --target-os=linux --target-arch=x64 -o "%RELEASE%\karmashala_host-!APPVERSHORT!-linux-x64" >> "%LOG%" 2>&1
if errorlevel 1 goto :fail
"%DARTEXE%" compile exe host\bin\karmashala_host.dart --target-os=linux --target-arch=arm64 -o "%RELEASE%\karmashala_host-!APPVERSHORT!-linux-arm64" >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

rem And the same host for *this* machine, which is the local stage: the app
rem starts it when a pane needs one and finds none running.
rem
rem Deliberately named without the `-<os>-<arch>` suffix the deployed ones
rem carry, because DirectoryHostBinaries matches on exactly that pattern and
rem this binary must never be uploaded to somebody else's machine — it is a
rem Windows PE. LocalHostExecutable looks for this name beside the app, the way
rem karmashala_mcp.exe is found, so the installer needs no change.
"%DARTEXE%" compile exe host\bin\karmashala_host.dart -o "%RELEASE%\karmashala_host.exe" >> "%LOG%" 2>&1
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
