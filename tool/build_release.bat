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
call "%FLUTTER%" pub get --directory packages\mcp_bridge >> "%LOG%" 2>&1
if errorlevel 1 goto :fail
"%DARTEXE%" compile exe packages\mcp_bridge\bin\karmashala_mcp.dart -o "%RELEASE%\karmashala_mcp.exe" >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

rem The session host for *this* machine, which is the local stage: the app
rem starts it when a pane needs one and finds none running.
rem
rem `dart build cli`, not `compile exe`, since 2026-09-15: the host carries the
rem app's store, so it depends on sqlite3, and `compile exe` refuses any target
rem with a build hook ("does not support build hooks"). No `pub get` here either
rem — packages\host is a workspace member now and the root resolution covers it.
rem
rem The output is a bundle, so it keeps its shape: the executable finds its
rem SQLite at ..\lib and cannot be flattened beside karmashala.exe. It lands in
rem Release\host\, which the installer copies wholesale
rem (karmashala.iss recurses subdirectories), and LocalHostExecutable looks
rem there first.
echo === SESSION HOST (this machine) === >> "%LOG%"
if exist "%RELEASE%\host" rmdir /s /q "%RELEASE%\host"
"%DARTEXE%" build cli -t packages\host\bin\karmashala_host.dart -o build\host-windows >> "%LOG%" 2>&1
if errorlevel 1 goto :fail
xcopy /e /i /y "build\host-windows\bundle" "%RELEASE%\host" >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

rem The hosts that get deployed to other machines are NOT built here.
rem
rem Measured 2026-09-15: a Linux bundle cross-compiled on Windows writes the
rem bundled library's relative path with *this* machine's separator, so it hunts
rem for `..\lib\libsqlite3.so` on the far end and cannot open a store. The ELF
rem and the .so are both fine — only the path is wrong — so there is nothing to
rem patch around, and `karmashala_host probe-store` reports it as
rem STORE MISLINKED. Linux bundles are therefore built on Linux, by the
rem `build-host-linux` job in .github/workflows/release-build.yml, and collected
rem from the release here.
rem
rem The version is in the filename because HostDeployer compares it against what
rem the remote binary reports rather than trusting the name.
echo === SESSION HOST (linux, from the release) === >> "%LOG%"
gh release download v!APPVERSHORT! -p "karmashala_host-*-linux-*" -D "%RELEASE%" >> "%LOG%" 2>&1
if errorlevel 1 (
  echo     no linux host bundles on release v!APPVERSHORT! yet - SSH deploy will report noBinary
  echo no linux host bundles on release v!APPVERSHORT! >> "%LOG%"
)

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
