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
set RELEASE=app\build\windows\x64\runner\Release
del /q "%DONE%" 2>nul

rem A one-shot request for the Windows installer alone: the scheduled task
rem takes no arguments, so this file asks instead, and is consumed here so the
rem next build is a full one again.
set WINDOWS_ONLY=
set WINDOWS_ONLY_FLAG=%USERPROFILE%\karmashala-build.windows-only
if exist "%WINDOWS_ONLY_FLAG%" (
  set WINDOWS_ONLY=1
  del /q "%WINDOWS_ONLY_FLAG%" 2>nul
)

rem Read the version straight out of app\pubspec.yaml so it cannot drift from what
rem was built. "version: 1.2.0+12" -> APPVER=1.2.0+12, APPVERSHORT=1.2.0.
rem If this fails APPVER stays empty and the app logs "version not recorded",
rem which is the honest outcome rather than a stale number.
set APPVER=
for /f "tokens=2" %%v in ('findstr /b "version:" app\pubspec.yaml') do set APPVER=%%v
for /f "delims=+" %%a in ("!APPVER!") do set APPVERSHORT=%%a
if "!APPVERSHORT!"=="" set APPVERSHORT=1.2.0
echo === BUILDING !APPVER! === > "%LOG%"

rem The host reports the same release, and `dart build cli` takes no define for
rem it: write the pubspec's into kHostVersion before anything is built.
"%DARTEXE%" tool\sync_host_version.dart >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

echo === WINDOWS RELEASE === >> "%LOG%"
rem The Flutter client is app\; everything else here runs from the root.
pushd app
call "%FLUTTER%" build windows --release --dart-define=KARMASHALA_VERSION=!APPVER! --dart-define=KARMASHALA_RELAY_URL=wss://kmrelay.popupbits.com >> "%LOG%" 2>&1
set RC=!errorlevel!
popd
if not "!RC!"=="0" goto :fail

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
rem — server is a workspace member and the root resolution covers it.
rem
rem The output is a bundle, so it keeps its shape: the executable finds its
rem SQLite at ..\lib and cannot be flattened beside karmashala.exe. It lands in
rem Release\host\, which the installer copies wholesale
rem (karmashala.iss recurses subdirectories), and LocalHostExecutable looks
rem there first.
echo === SESSION HOST (this machine) === >> "%LOG%"
if exist "%RELEASE%\host" rmdir /s /q "%RELEASE%\host"
rem Into server\build (git-ignored there), not a root build\: the repo root is
rem a pub workspace with no build of its own since the move into app\.
"%DARTEXE%" build cli -t server\bin\karmashala_host.dart -o server\build\host-windows >> "%LOG%" 2>&1
if errorlevel 1 goto :fail
xcopy /e /i /y "server\build\host-windows\bundle" "%RELEASE%\host" >> "%LOG%" 2>&1
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
rem from the release here - or, when the release has none, built in WSL below.
rem
rem The version is in the filename because HostDeployer compares it against what
rem the remote binary reports rather than trusting the name.
rem
rem Whatever is already in Release stays and ships: the installer deletes
rem nothing, so a failed download means an SSH host gets an *older* host, not
rem none. Say which failure it was - "no bundles on the release" was printed
rem on a machine that had no gh at all.
echo === SESSION HOST (linux, from the release) === >> "%LOG%"
rem Windows' gh, or else WSL's: gh signed in inside WSL downloads straight
rem into the Release folder through its /mnt path.
set GH=
where gh >nul 2>nul
if not errorlevel 1 set GH=windows
if not defined GH (
  wsl.exe -e sh -c "command -v gh" >nul 2>nul
  if not errorlevel 1 set GH=wsl
)
if not defined GH (
  echo     gh is not installed on Windows or in WSL - linux host bundles NOT fetched; SSH hosts get whatever older bundle is already in %RELEASE%
  echo gh is not installed on Windows or in WSL - linux host bundles not fetched >> "%LOG%"
) else (
  if "!GH!"=="windows" (
    gh release download v!APPVERSHORT! -p "karmashala_host-*-linux-*" -D "%RELEASE%" >> "%LOG%" 2>&1
  ) else (
    for /f "delims=" %%w in ('wsl.exe wslpath -a "%CD%\%RELEASE%"') do set WSLRELEASE=%%w
    echo downloading through WSL's gh into !WSLRELEASE! >> "%LOG%"
    wsl.exe -e gh release download v!APPVERSHORT! -R lohanidamodar/karmashala -p "karmashala_host-*-linux-*" -D "!WSLRELEASE!" >> "%LOG%" 2>&1
  )
  if errorlevel 1 (
    echo     could not download linux host bundles from release v!APPVERSHORT! - SSH hosts get whatever older bundle is already in %RELEASE%
    echo could not download linux host bundles from release v!APPVERSHORT! >> "%LOG%"
  )
)

rem No release bundles for this version (no gh, no release yet, a failed
rem download): build them in WSL from the commit being built, by the CI job's
rem commands, with WSL's own Flutter SDK - tool\build_host_linux.dart says how.
rem Loud but not fatal: the installer still builds, with whatever older bundle
rem is already in Release.
if not exist "%RELEASE%\karmashala_host-!APPVERSHORT!-linux-x64.tar.gz" (
  echo === SESSION HOST ^(linux, built in WSL^) === >> "%LOG%"
  "%DARTEXE%" tool\build_host_linux.dart --version !APPVERSHORT! --out "%RELEASE%" >> "%LOG%" 2>&1
  if errorlevel 1 (
    echo     LINUX HOST BUNDLES NOT BUILT in WSL - SSH hosts get whatever older bundle is already in %RELEASE%; see %LOG%
    echo LINUX HOST BUNDLES NOT BUILT in WSL - SSH hosts get whatever older bundle is already in %RELEASE% >> "%LOG%"
  )
)

echo === INSTALLER === >> "%LOG%"
"%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe" /DMyAppVersion=!APPVERSHORT! app\windows\installer\karmashala.iss >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

if defined WINDOWS_ONLY (
  echo === ANDROID SKIPPED: windows-only build requested === >> "%LOG%"
  goto :done
)

rem The APK is signed by app\android\key.properties when present, else the
rem debug key.
echo === ANDROID APK (the one app) === >> "%LOG%"
rem Without app\android\key.properties gradle signs with the debug key, and that
rem APK will not install over a release one: refuse rather than build it.
if not exist "app\android\key.properties" (
  echo     app\android\key.properties is missing - a release APK would be signed with the debug key
  echo app\android\key.properties is missing - refusing to sign the release APK with the debug key >> "%LOG%"
  goto :fail
)
pushd app
call "%FLUTTER%" build apk --release --dart-define=KARMASHALA_VERSION=!APPVER! --dart-define=KARMASHALA_RELAY_URL=wss://kmrelay.popupbits.com >> "%LOG%" 2>&1
set RC=!errorlevel!
popd
if not "!RC!"=="0" goto :fail

:done
echo OK > "%DONE%"
exit /b 0
:fail
echo FAIL > "%DONE%"
exit /b 1
