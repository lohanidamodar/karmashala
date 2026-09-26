<#
.SYNOPSIS
  Runs the opt-in live tests — the ones the ordinary gate excludes.

.DESCRIPTION
  `flutter test --exclude-tags=live-ssh,live-wsl` is the default gate, and it is
  right: those tests bind real sockets, drive a real WSL distribution and dial a
  real SSH server, and making the ordinary suite depend on that would be a worse
  bug than the ones they catch. But a test nobody ever runs is a comment, and
  these exist to catch exactly the failures no stand-in can see — a hook
  endpoint a Windows process binds that is not reachable from inside a WSL
  network namespace being the one that has been silently degrading agent status
  on this machine.

  So they are opt-in and deliberate: this script is the deliberate part. It
  reports what it found before running anything, so a run that proves nothing
  cannot be mistaken for a run that proved something, and it uses the expanded
  reporter so a self-skip prints its reason instead of a bare "~1".

.PARAMETER Family
  wsl | ssh | all (default). `ssh` needs KARMASHALA_SSH_HOST, _USER and _KEY in
  the environment; without them those tests skip themselves and say so.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tool\live_tests.ps1
  powershell -ExecutionPolicy Bypass -File tool\live_tests.ps1 -Family wsl

  Windows PowerShell 5.1 is enough — no `#requires`, no 7-only syntax. Do not
  write `pwsh` here: PowerShell 7 is not installed on the machine this script
  exists for. Keep `-ExecutionPolicy Bypass` too: the policy here is
  `Restricted`, so invoking the file directly raises PSSecurityException.

.NOTES
  Never run this from a WSL shell. Bare `flutter` there resolves to the POSIX
  script inside the Windows install and swaps a Linux Dart SDK into it — see
  CLAUDE.md §17. This is a Windows script for a Windows toolchain.
#>
param(
  [ValidateSet('wsl', 'ssh', 'all')]
  [string]$Family = 'all'
)

$ErrorActionPreference = 'Stop'
# The Flutter client, app\ beside this folder: the suites below are its.
$root = Join-Path (Split-Path -Parent $PSScriptRoot) 'app'
Set-Location $root

function Test-WslReady {
  # A distribution that answers is the whole prerequisite now: the hook
  # transport writes a file across the share rather than running `curl`. The
  # `/mcp` measurement at the end of the hook suite still wants one, and says
  # so itself when there is none.
  try {
    $hello = & wsl.exe -e sh -c 'echo ready'
    return ($LASTEXITCODE -eq 0 -and "$hello" -match 'ready')
  } catch {
    return $false
  }
}

$sshReady = $env:KARMASHALA_SSH_HOST -and $env:KARMASHALA_SSH_USER -and $env:KARMASHALA_SSH_KEY
$wslReady = Test-WslReady

# What this run can and cannot prove, said before it starts. A green run whose
# prerequisites were absent proved nothing, and that must not look like a pass.
Write-Host ''
Write-Host 'Live test prerequisites' -ForegroundColor Cyan
Write-Host ("  WSL distribution           : " + $(if ($wslReady) { 'present' } else { 'ABSENT - the WSL tests will skip themselves' }))
Write-Host ("  KARMASHALA_SSH_* set       : " + $(if ($sshReady) { 'yes' } else { 'no - the SSH tests will skip themselves' }))
Write-Host ''

$suites = @()
if ($Family -in @('wsl', 'all')) {
  $suites += [pscustomobject]@{
    Name  = 'WSL'
    Tag   = 'live-wsl'
    Files = @(
      'test/features/agents/live_wsl_hook_test.dart',
      'test/features/projects/live_wsl_path_existence_test.dart',
      'test/terminal/live_wsl_pane_test.dart',
      'test/terminal/live_wsl_prompt_test.dart',
      'test/terminal/live_wsl_input_boundary_test.dart'
    )
  }
}
if ($Family -in @('ssh', 'all')) {
  $suites += [pscustomobject]@{
    Name  = 'SSH'
    Tag   = 'live-ssh'
    Files = @(
      'test/features/ssh/live_ssh_test.dart',
      'test/features/ssh/live_ssh_ui_test.dart'
    )
  }
}

$failed = @()
foreach ($suite in $suites) {
  Write-Host "== $($suite.Name) live tests ($($suite.Tag)) ==" -ForegroundColor Cyan
  # --tags selects only these; --reporter expanded is what makes a skip print
  # the reason it was skipped for rather than a silent tally.
  & flutter test @($suite.Files) --tags $suite.Tag --reporter expanded
  if ($LASTEXITCODE -ne 0) { $failed += $suite.Name }
  Write-Host ''
}

if ($failed.Count -gt 0) {
  Write-Host "Live tests FAILED: $($failed -join ', ')" -ForegroundColor Red
  Write-Host 'Read the failure text before filing anything: these tests name'
  Write-Host 'whether the fault is THIS MACHINE or THE APP, and the two need'
  Write-Host 'opposite responses.'
  exit 1
}

Write-Host 'Live tests passed (or skipped themselves for a stated reason).' -ForegroundColor Green
