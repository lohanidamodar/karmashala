# Launches a real debug build, asks it to quit the way the window's X does, and
# counts what is left — N times. From Windows PowerShell, never a WSL shell:
# §17 applies here exactly as it does to `reliability_soak.ps1`, and `& flutter`
# below resolves to `flutter.bat` only on the Windows PATH.
#
#   powershell -ExecutionPolicy Bypass -File tool\app_soak.ps1
#   powershell -ExecutionPolicy Bypass -File tool\app_soak.ps1 -Iterations 5
#
# `reliability_soak.ps1` is the *test* soak: it re-runs seven flake-prone suites
# and launches nothing, which is what makes it safe beside a live install. This
# is the opposite case — it starts the app — and everything under "isolation"
# below is what makes it safe anyway.
#
# ## The quit is asked for, never imposed
#
# `Process.CloseMainWindow()` posts `WM_CLOSE` to the app's window, which is the
# same message the X sends. Prevent-close is on unconditionally
# (`SystemIntegrationService.apply`), so the message reaches Dart, and
# `onWindowClose` runs the ordered teardown the tray's Quit runs —
# `AppLifecycle.shutdown()`, then `destroy()`, then `exit(0)`. Nothing here
# kills anything; a cycle whose app does not exit within `-QuitTimeoutSeconds`
# is a **failed** cycle, and only then is that one process — verified to be this
# build's own exe — stopped, so a hang cannot leave an instance holding the
# global hotkey.
#
# ## Isolation: three switches, none of them optional
#
# * **`KARMASHALA_DATA_DIR`** — the database, the handshake file, the RPC socket,
#   the logs, the vault (`core/paths/app_support_directory.dart`). Without it a
#   launched build shares the installed app's data: `path_provider` resolves the
#   Windows support directory through `SHGetKnownFolderPath`, so redirecting
#   `%APPDATA%` moves nothing. This script refuses to start if the directory it
#   would use is the installed app's, and cycle 1 refuses to continue unless
#   `karmashala.sqlite` has appeared under the scratch directory — the override
#   is proved, not trusted.
# * **`USERPROFILE` / `HOME`** — the *agent* store homes. Every launch installs
#   status hooks into `~/.claude`, `~/.codex` and `~/.gemini/antigravity-cli`,
#   and every quit deletes the endpoint file again (`AppLifecycle` step 1b →
#   `AgentHookInstaller.retireEndpoint`). Against the real home, twenty quits
#   would end with the installed app's agents holding a script that finds no
#   endpoint file and reports nothing until that app is restarted.
# * **A `wsl.exe` that fails** — the WSL store homes, which are where most of
#   this owner's agent sessions live. They come from *inside* the distribution
#   (`CliDetectionService._wslHome` runs `bash -lc 'printf %s "$HOME"'`), so no
#   variable on this side moves them. The app is instead given a working
#   directory holding a `wsl.exe` that exits non-zero: `CreateProcess` searches
#   the calling process's own current directory before `System32`, so
#   `EnvironmentDiscoveryService` finds no distributions and the hook sweep has
#   nothing outside the scratch home to reach. Cycle 1 checks the log for
#   `Discovered 1 execution environment(s).` and stops if it is more, because a
#   guard that silently stopped working is worse than none.
#
# ## What it counts, per cycle
#
# Processes whose command line names this worktree and were not there before the
# first launch; the handshake file; the owner-only socket node; lock files
# (`*.lock`, and SQLite's `-wal`/`-shm`, which a clean close removes and a kill
# leaves); and the scratch directory's size, so growth over a run is visible.
# The quit cost is the one thing here that is timed, and it is read from the
# line the lifecycle logs itself (`lifecycle: shutdown in N ms.`) rather than
# measured from outside, so it is the app's own accounting.
#
# ## Last recorded run — 2026-09-09, 1.19.0+35 at 1384fdce
#
# 20 cycles from a worktree, with the installed app and five sibling agents live
# on the same machine. **It is not green, and the numbers are why it exists.**
#
#   cycles                 20 launched, 20 came up, 18 quit on the close message
#   launch to handshake    5775-10049 ms, mean 8523 — a debug build, JIT, under
#                          five agents' test runs; a release build is not this
#   quit, wall clock       2767-3766 ms on the 18 that exited
#   quit, as logged        1779-2296 ms, median 2052 — `AppLifecycle`'s own
#                          number, and it is *within* 2550 only because the
#                          terminal step is abandoned at its 1500 ms cap on
#                          every single cycle
#   processes left behind  0 of 20 — nothing naming this worktree survived a
#                          cycle, including the two that had to be stopped
#   scratch data           1.14 -> 1.31 MB over 20 cycles, ~8 KB a cycle
#
# Three things this found that no unit test with a fake had:
#
# * **Two cycles never exited.** 8 and 12 ignored the close message for the full
#   60 s and were stopped. Both had come up and both had a window; nothing in
#   the log distinguishes them from the 18 that quit.
# * **18 of 20 left `mcp_bridge.json` and `ipc\rpc.sock` on disk.** Only cycles
#   2 and 3 removed both. `LauncherControlServer.stop()` removes them in its
#   synchronous prefix and the lifecycle runs it as step 3, before the terminal
#   step that is abandoned — and the log carries no `skipped control server`,
#   no `control server did not finish` and no `control server failed`. So a
#   stale handshake advertising a dead port is the *usual* outcome of a quit
#   here, which is the exact failure that ordering was written to prevent.
# * **The log loses its own tail.** 20 starts, 17 `window close` lines, 8
#   `shutdown in N ms` lines. The duration this script reports as `?` is a line
#   the app wrote and the file never received, so `lifecycle`'s account of its
#   own quit is missing more often than it is present.
#
# `karmashala.sqlite-wal` and `-shm` are left by all 20 and are counted here,
# but they are not in the list above: the database is closed by `exit(0)` rather
# than by a `close()`, so SQLite has no chance to remove them and the next
# launch recovers from them. Worth knowing, not worth fixing here.
#
# The isolation held, and was measured rather than assumed. Every cycle logged
# `wsl.exe --list exited 1; no WSL distributions added.` and
# `Discovered 1 execution environment(s).`; the live `~/.claude` and `~/.codex`
# endpoint files still carried their 2026-09-08 timestamps afterwards; and every
# cycle logged `Port 47821 is taken, so this run uses an ephemeral one`, which
# is the installed app holding its own port throughout.

param(
  [int]$Iterations = 20,
  [string]$DataDir,
  [switch]$SkipBuild,
  [int]$ReadyTimeoutSeconds = 180,
  [int]$QuitTimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
Set-Location $root

function Get-FullPath([string]$path) { [IO.Path]::GetFullPath($path).TrimEnd('\') }
function Test-Under([string]$child, [string]$parent) {
  $c = Get-FullPath $child
  $p = Get-FullPath $parent
  return ($c -eq $p) -or $c.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase)
}

$scratch = Join-Path $root 'build\app-soak'
if (-not $DataDir) { $DataDir = Join-Path $scratch 'data' }
$data = Get-FullPath $DataDir
$fakeHome = Get-FullPath (Join-Path $scratch 'home')
$stubBin = Get-FullPath (Join-Path $scratch 'bin')
$installedData = Get-FullPath (Join-Path $env:APPDATA 'com.popupbits\karmashala')

# The one refusal that is not about tidiness. Everything this soak does to a
# data directory — twenty launches, twenty quits, a growth measurement — is
# something no one would want done to the data they are using.
if ((Test-Under $data $installedData) -or (Test-Under $installedData $data)) {
  throw "Refusing to run: $data is the installed app's data directory ($installedData)."
}
if (-not (Test-Under $data $root)) {
  throw "Refusing to run: $data is outside this checkout ($root)."
}

$exe = Join-Path $root 'build\windows\x64\runner\Debug\karmashala.exe'
$flutter = Join-Path $env:USERPROFILE 'flutter\bin\flutter.bat'
$appVer = ((Select-String -Path (Join-Path $root 'pubspec.yaml') -Pattern '^version:' |
    Select-Object -First 1).Line -split '\s+')[1]

if (-not $SkipBuild) {
  Write-Host "Building $appVer debug for windows ..."
  & $flutter build windows --debug "--dart-define=KARMASHALA_VERSION=$appVer"
  if ($LASTEXITCODE -ne 0) { throw "flutter build windows --debug failed ($LASTEXITCODE)." }
}
if (-not (Test-Path $exe)) { throw "No debug binary at $exe. Run without -SkipBuild." }

New-Item -ItemType Directory -Force -Path $data, $fakeHome, $stubBin | Out-Null
foreach ($storeHome in @('.claude', '.codex', '.gemini\antigravity-cli', '.gemini\config')) {
  New-Item -ItemType Directory -Force -Path (Join-Path $fakeHome $storeHome) | Out-Null
}
# `where.exe` is the stub because it is a real Windows binary that exits
# non-zero for every argument list this app passes `wsl.exe`, and is on every
# machine that can run this script.
$stubWsl = Join-Path $stubBin 'wsl.exe'
if (Test-Path $stubWsl) { Remove-Item $stubWsl -Force }
Copy-Item (Join-Path $env:SystemRoot 'System32\where.exe') $stubWsl
Set-ItemProperty -Path $stubWsl -Name IsReadOnly -Value $false

$handshake = Join-Path $data 'mcp_bridge.json'
$socketNode = Join-Path $data 'ipc\rpc.sock'
$logFile = Join-Path $data 'logs\karmashala.log'

# `$root\` and not `$root`: a sibling worktree at `...\app-soak-load` starts
# with this one's path and its test processes are not something a cycle left.
$mine = [regex]::Escape($root + '\')
function Get-SoakProcess {
  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match $mine }
}
function Measure-Shutdowns {
  if (-not (Test-Path $logFile)) { return @() }
  return @(Select-String -Path $logFile -Pattern 'shutdown in (\d+) ms' -ErrorAction SilentlyContinue)
}

$savedProfile = $env:USERPROFILE
$savedHome = $env:HOME
$savedData = $env:KARMASHALA_DATA_DIR
$rows = @()
$failures = 0

try {
  $env:KARMASHALA_DATA_DIR = $data
  $env:USERPROFILE = $fakeHome
  $env:HOME = $fakeHome

  # After the build, so the toolchain's own processes are not counted as
  # something a cycle left behind.
  $baseline = @(Get-SoakProcess | ForEach-Object { $_.ProcessId })
  Write-Host "Soaking $Iterations cycle(s) of $exe"
  Write-Host "  data   $data"
  Write-Host "  home   $fakeHome"
  Write-Host ''

  for ($i = 1; $i -le $Iterations; $i++) {
    Remove-Item $handshake -Force -ErrorAction SilentlyContinue
    $shutdownsBefore = (Measure-Shutdowns).Count

    $launched = Get-Date
    $proc = Start-Process -FilePath $exe -WorkingDirectory $stubBin -PassThru
    $ready = $false
    $readyBy = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
    while ((Get-Date) -lt $readyBy) {
      if ($proc.HasExited) { break }
      if (Test-Path $handshake) {
        $raw = Get-Content -Raw -Path $handshake -ErrorAction SilentlyContinue
        if ($raw -and $raw.Trim().EndsWith('}')) { $ready = $true; break }
      }
      Start-Sleep -Milliseconds 200
    }
    $upMs = [int]((Get-Date) - $launched).TotalMilliseconds

    $asked = $false
    $quitAsked = Get-Date
    if ($ready) {
      $askBy = (Get-Date).AddSeconds(30)
      while (-not $asked -and (Get-Date) -lt $askBy -and -not $proc.HasExited) {
        $proc.Refresh()
        if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
          $quitAsked = Get-Date
          $asked = $proc.CloseMainWindow()
        }
        if (-not $asked) { Start-Sleep -Milliseconds 200 }
      }
    }
    $exited = $false
    if ($asked) { $exited = $proc.WaitForExit($QuitTimeoutSeconds * 1000) }
    $quitMs = [int]((Get-Date) - $quitAsked).TotalMilliseconds

    # Only ever this build's own executable, only after it refused a close it
    # was asked for, and the cycle is a failure either way.
    if (-not $proc.HasExited) {
      if ($proc.Path -eq $exe) { Stop-Process -Id $proc.Id -Force }
      $exited = $false
    }

    $loggedMs = $null
    $shutdowns = Measure-Shutdowns
    if ($shutdowns.Count -gt $shutdownsBefore) {
      $loggedMs = [int]$shutdowns[-1].Matches[0].Groups[1].Value
    }

    if ($i -eq 1) {
      if (-not (Test-Path (Join-Path $data 'karmashala.sqlite'))) {
        throw ("KARMASHALA_DATA_DIR did not take effect: no karmashala.sqlite under $data " +
          'after a full launch. Stopping before a second one runs against the live data.')
      }
      $found = @(Select-String -Path $logFile -Pattern 'Discovered (\d+) execution environment' `
          -ErrorAction SilentlyContinue)
      if ($found.Count -gt 0 -and [int]$found[-1].Matches[0].Groups[1].Value -ne 1) {
        throw ("The wsl.exe stub did not take: the app discovered " +
          "$($found[-1].Matches[0].Groups[1].Value) environments, so it can reach the " +
          "owner's WSL agent homes. Stopping.")
      }
    }

    $strayProcs = @(Get-SoakProcess | Where-Object { $baseline -notcontains $_.ProcessId })
    $locks = @(Get-ChildItem -Path $data -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object {
          -not $_.PSIsContainer -and
          ($_.Name -like '*.lock' -or $_.Name -like '*-wal' -or $_.Name -like '*-shm')
        })
    $sizeMb = [math]::Round(((Get-ChildItem -Path $data -Recurse -Force -ErrorAction SilentlyContinue |
          Measure-Object -Property Length -Sum).Sum) / 1MB, 2)

    # Named rather than counted, because "a cycle failed" and "a cycle quit
    # cleanly and left its handshake behind" are different reports.
    $wrong = @()
    if (-not $ready) { $wrong += 'never came up' }
    if (-not $asked) { $wrong += 'no window to close' }
    if (-not $exited) { $wrong += 'did not exit' }
    elseif ($proc.ExitCode -ne 0) { $wrong += "exit $($proc.ExitCode)" }
    if ($strayProcs.Count -ne 0) { $wrong += "$($strayProcs.Count) process(es) left" }
    if (Test-Path $handshake) { $wrong += 'handshake left' }
    if (Test-Path $socketNode) { $wrong += 'socket left' }
    if ($locks.Count -ne 0) { $wrong += "$($locks.Count) lock file(s) left" }
    $ok = $wrong.Count -eq 0
    if (-not $ok) { $failures++ }

    $rows += [pscustomobject]@{
      cycle     = $i
      upMs      = $upMs
      quitMs    = $quitMs
      loggedMs  = $loggedMs
      exitCode  = $(if ($proc.HasExited) { $proc.ExitCode } else { 'running' })
      strays    = $strayProcs.Count
      handshake = [int](Test-Path $handshake)
      socket    = [int](Test-Path $socketNode)
      locks     = $locks.Count
      dataMb    = $sizeMb
      ok        = $ok
    }
    $line = 'cycle {0,2}  up {1,6} ms  quit {2,5} ms  logged {3,5} ms  exit {4}  ' +
      'strays {5}  handshake {6}  socket {7}  locks {8}  data {9} MB  {10}'
    Write-Host ($line -f
      $i, $upMs, $quitMs, $(if ($null -eq $loggedMs) { '?' } else { $loggedMs }),
      $rows[-1].exitCode, $strayProcs.Count, $rows[-1].handshake, $rows[-1].socket,
      $locks.Count, $sizeMb, $(if ($ok) { 'ok' } else { 'FAILED: ' + ($wrong -join ', ') }))
  }
} finally {
  $env:USERPROFILE = $savedProfile
  if ($null -eq $savedHome) { Remove-Item Env:\HOME -ErrorAction SilentlyContinue }
  else { $env:HOME = $savedHome }
  if ($null -eq $savedData) { Remove-Item Env:\KARMASHALA_DATA_DIR -ErrorAction SilentlyContinue }
  else { $env:KARMASHALA_DATA_DIR = $savedData }
}

$logged = @($rows | Where-Object { $null -ne $_.loggedMs } | ForEach-Object { $_.loggedMs })
Write-Host ''
Write-Host ("cycles             {0} / {1}" -f ($rows.Count - $failures), $Iterations)
if ($logged.Count -gt 0) {
  Write-Host ("shutdown, logged   {0}-{1} ms, median {2} ms" -f
    ($logged | Measure-Object -Minimum).Minimum,
    ($logged | Measure-Object -Maximum).Maximum,
    ($logged | Sort-Object)[[int]($logged.Count / 2)])
}
Write-Host ("launch to handshake {0}-{1} ms" -f
  ($rows.upMs | Measure-Object -Minimum).Minimum,
  ($rows.upMs | Measure-Object -Maximum).Maximum)
Write-Host ("processes left     {0}" -f ($rows.strays | Measure-Object -Sum).Sum)
Write-Host ("handshakes left    {0}" -f ($rows.handshake | Measure-Object -Sum).Sum)
Write-Host ("socket nodes left  {0}" -f ($rows.socket | Measure-Object -Sum).Sum)
Write-Host ("lock files left    {0}" -f ($rows.locks | Measure-Object -Sum).Sum)
Write-Host ("scratch data       {0} -> {1} MB" -f $rows[0].dataMb, $rows[-1].dataMb)

if ($failures -ne 0) {
  Write-Host "App soak FAILED $failures of $Iterations cycle(s)."
  exit 1
}
Write-Host "App soak passed $Iterations cycle(s)."
