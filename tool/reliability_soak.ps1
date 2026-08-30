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
