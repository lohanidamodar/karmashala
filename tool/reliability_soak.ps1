# Repeats the flake-prone suites until a flake that survives one green run shows
# itself. From Windows PowerShell, never a WSL shell — §17 applies here too, and
# `& flutter` below resolves to `flutter.bat` only on the Windows PATH:
#
#   powershell -ExecutionPolicy Bypass -File tool\reliability_soak.ps1
#
# It is a *test* soak, not an app soak, which is what makes it safe beside a live
# install: nothing here launches Karmashala, so nothing here opens the real
# database. Every suite builds its own state — `AppDatabase.memory()`, a temp
# directory, an OS-chosen ephemeral port rather than the production fixed one.
# `debug_run.bat` is the opposite case and says so: a debug run resolves the
# support directory through `SHGetKnownFolderPath` and shares the installed app's
# data unless `KARMASHALA_DATA_DIR` is set (`core/paths/app_support_directory.dart`).
#
# ## Last recorded run — 2026-09-09, 1.19.0+35 at 58df1eca
#
# 20/20 green, from a worktree while the installed app and five sibling agents
# were live on the same machine.
#
#   iterations             20 / 20, no retries
#   test runs              40 — the seven suites, then test\terminal\perf
#   tests per run          76 and 28, the same count every iteration, so nothing
#                          skipped itself under load
#   failures               0
#   wall clock             1132 s total; 56.6 s per iteration
#                          failure suites 30-35 s, perf suites 6-9 s
#   processes left behind  0 — sampled every 5 s across the run (193 samples),
#                          peak 5 concurrent, none naming the worktree survived
#   files left behind      0 — no sqlite3.dll lock failure, no orphaned tester
#   Application event log  nothing from this run; only Windows Update and VSS
#
# The only contention was one "Waiting for another flutter command to release the
# startup lock" on stderr — a sibling agent's gate, which cleared on its own.
# Parallel gates serialise here; they do not fail.

param(
  [int]$Iterations = 20,
  [switch]$IncludeLive
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$failureSuites = @(
  'test/features/terminal/session_lifetime_test.dart',
  'test/features/terminal/process_shutdown_test.dart',
  'test/features/ssh/reconnect_backoff_test.dart',
  'test/features/ssh/ssh_connection_test.dart',
  'test/features/devices/device_stream_test.dart',
  'test/features/browser/cdp_connection_test.dart',
  'test/features/mcp/agent_hook_route_test.dart'
)

for ($iteration = 1; $iteration -le $Iterations; $iteration++) {
  Write-Host "Reliability iteration $iteration / $Iterations"
  & flutter test @failureSuites --reporter compact
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

  & flutter test test/terminal/perf --reporter compact
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

  if ($IncludeLive) {
    & flutter test test/features/ssh/live_ssh_test.dart --run-skipped
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  }
}

Write-Host "Reliability soak passed $Iterations iteration(s)."
