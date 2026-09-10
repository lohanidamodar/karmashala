<#
.SYNOPSIS
  The per-change gate: a package's own `dart test` plus the app suites that
  exercise it. `-Full` is still the pre-merge gate.

.DESCRIPTION
  The full gate is ~16 minutes and reruns 864 suites to prove a change in one
  of them. docs/PACKAGE_SPLIT.md §4 splits that: a change in package X runs X's
  own `dart test` — no `flutter_tester`, no `sqlite3.dll`, no exit hang — plus
  the app folders that exercise X and whichever golden has X in its import
  closure. That is 1-3 minutes. The full gate stays the pre-merge check, not
  the per-edit one.

  Three rules the script keeps:

  * Cost and soak suites are excluded from a package run (`--exclude-tags=
    live-ssh,live-wsl,cost`). They are wall-clock measurements, not behaviour,
    and the full gate still runs them.
  * Goldens run read-only. This script never sets a `KARMASHALA_WRITE_*`
    variable, and refuses to start if one is set in the environment, because a
    gate that rewrites the thing it is checking proves nothing.
  * `test/terminal/perf/**` is frozen and runs under `-Full` only.

  Every run's output goes to `.gate\<name>.txt` and the exit code is read from
  `$LASTEXITCODE` straight after the call, never through a pipe: a gate whose
  verdict is laundered by another command reports green for a red run.

.PARAMETER Package
  A key of the map below. Every one of the fourteen — `core`, `media`,
  `agent_cli`, `agent_reporting`, `browser`, `devices`, `mcp`, `remote`,
  `session`, `ssh`, `git`, `flutter_apps`, `terminal_core` and `ui` — is
  extracted and cut over: the app holds no copy of any of them.

.PARAMETER Changed
  Map `git diff --name-only` (against the merge base with main, plus anything
  uncommitted) onto packages and run each. Anything that touches the app shell,
  a pubspec or the test harness falls back to `-Full`.

.PARAMETER Full
  The ordinary full gate: `flutter test --exclude-tags=live-ssh,live-wsl`.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tool\gate.ps1 -Package core
  powershell -ExecutionPolicy Bypass -File tool\gate.ps1 -Changed
  powershell -ExecutionPolicy Bypass -File tool\gate.ps1 -Full

  Windows PowerShell 5.1 is enough — no `#requires`, no 7-only syntax, and do
  not write `pwsh`: PowerShell 7 is not installed on the machine this script
  exists for. Keep `-ExecutionPolicy Bypass`; the policy here is `Restricted`.

.NOTES
  Never run this from a WSL shell. Bare `flutter` there resolves to the POSIX
  script inside the Windows install and swaps a Linux Dart SDK into it — see
  CLAUDE.md §17. This is a Windows script for a Windows toolchain.
#>
param(
  [string]$Package,
  [switch]$Changed,
  [switch]$Full
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$flutter = Join-Path $env:USERPROFILE 'flutter\bin\flutter.bat'
$dart    = Join-Path $env:USERPROFILE 'flutter\bin\cache\dart-sdk\bin\dart.exe'
$gateDir = Join-Path $root '.gate'
if (-not (Test-Path $gateDir)) { New-Item -ItemType Directory -Path $gateDir | Out-Null }

# Which package owns which app suites. `pkg` is the workspace member; `app` is
# the mirror folder(s) plus any golden whose import closure reaches the package.
# All fourteen are extracted and cut over, so every mapping here is a real seam:
# no key names a folder the app still keeps a second copy of. `flutter = $true`
# marks a member whose own half needs `flutter test` rather than `dart test`.
$map = [ordered]@{
  core = @{
    pkg  = 'packages/karmashala_core'
    app  = @('test/core')
    owns = @('lib/src/core/logging', 'lib/src/core/util', 'lib/src/core/paths',
             'test/core')
  }
  media = @{
    pkg  = 'packages/karmashala_media'
    # The frame sinks and the H.264 writer; `lib/src/core/media` is the app's
    # provider over them, and the recorders are what exercise them end to end.
    app  = @('test/features/terminal',
             'test/features/mcp/recording_tools_test.dart')
    owns = @('lib/src/core/media')
  }
  agent_cli = @{
    pkg  = 'packages/agent_cli'
    # The three folders whole: what is left in them is the app's half — the
    # hook installer and spool, the DAOs, the controllers, the providers and
    # the pickers — and every suite in them now runs against the package's
    # types. Two goldens reach it: the tool schemas, because `list_agents` and
    # the session tools are served over its descriptors, and the launch
    # catalogue, because the argv it pins is `agent_cli`'s to build now.
    # (`test/core/process` is gone: its one remaining suite followed
    # `ssh_command_runner.dart` into `test/features/ssh`.)
    app  = @('test/features/agents', 'test/features/cli_detection',
             'test/features/environments',
             'test/features/mcp/tool_schemas_golden_test.dart',
             'test/features/sessions/session_launch_golden_test.dart')
    owns = @('lib/src/core/process', 'lib/src/features/agents',
             'lib/src/features/cli_detection', 'lib/src/features/environments',
             'test/features/agents', 'test/features/cli_detection',
             'test/features/environments')
  }
  agent_reporting = @{
    pkg  = 'packages/karmashala_agent_reporting'
    # `test/features/agents` whole: what is left in it is the app's half — the
    # four application services over the cli_detection, environment and
    # notification providers, the status providers, the DAOs and controllers,
    # the pickers and the usage chip — plus the grid-source suite, which
    # renders its rows through the app's `terminal_grid_text` and `xterm2`.
    # Eight suites outside the folder read a status this package produced: the
    # workbench, the four notification ones, the two session ones and the MCP
    # hook route. No golden is mapped: the hook scripts, the endpoint file and
    # the skill bytes are pinned by the package's own suites, and every agent
    # string in the six goldens is `agent_cli`'s descriptor table.
    app  = @('test/features/agents',
             'test/app/shell/workbench_test.dart',
             'test/features/cli_detection/codex_session_identity_test.dart',
             'test/features/mcp/agent_hook_route_test.dart',
             'test/features/notifications/agent_hook_route_status_test.dart',
             'test/features/notifications/agent_status_watcher_test.dart',
             'test/features/notifications/session_status_registry_test.dart',
             'test/features/notifications/watched_session_loader_test.dart',
             'test/features/sessions/agent_status_badge_cost_test.dart',
             'test/features/sessions/session_outcome_test.dart')
    # Nothing under `lib/` or `test/` is this package's alone: what remains of
    # `features/agents` is `agent_cli`'s app half, which already owns it.
    owns = @()
  }
  git = @{
    pkg  = 'packages/karmashala_git'
    # The three folders whole: what is left in them is the app's half — the
    # review-thread, worktree-setup and repository DAOs, the discovery service,
    # the `gh`-driven GitHub service, the providers and the views — and every
    # suite in them now runs against the package's types. One golden outside
    # them reaches it: the tool schemas, because `review_thread_*`,
    # `worktree_create`/`worktree_remove`, `checkpoint_diff` and
    # `list_checkouts` are served over the package's values.
    app  = @('test/features/git', 'test/features/github',
             'test/features/repositories',
             'test/features/mcp/tool_schemas_golden_test.dart')
    owns = @('lib/src/features/git', 'lib/src/features/github',
             'lib/src/features/repositories',
             'test/features/git', 'test/features/github',
             'test/features/repositories')
  }
  browser = @{
    pkg  = 'packages/karmashala_browser'
    app  = @('test/features/browser',
             'test/features/mcp/browser_tools_served_test.dart',
             'test/features/mcp/tool_schemas_golden_test.dart')
    owns = @('lib/src/features/browser', 'test/features/browser')
  }
  flutter_apps = @{
    pkg  = 'packages/karmashala_flutter_apps'
    # `test/features/flutter_apps` whole: what is left in it is the app's half
    # — the providers, `AttachedApps`, the loop and its gate observer, the SDK
    # readings and the two panes — plus the two fakes the package cannot lend
    # it. The tool schemas golden is the one golden outside the folder that
    # reaches the package: the six `flutter_*` tools are served over its types.
    app  = @('test/features/flutter_apps',
             'test/features/mcp/tool_schemas_golden_test.dart',
             # Reads the package's `readPubspec` from outside the mapped folder.
             'test/features/app_projects/project_descriptor_test.dart')
    owns = @('lib/src/features/flutter_apps', 'test/features/flutter_apps')
  }
  devices = @{
    pkg  = 'packages/karmashala_devices'
    # `test/features/devices` whole: what is left in it is the app's half —
    # the providers and controllers, the pane and its widgets, the pane tree
    # golden, and the three suites over the MCP device-tool family
    # (`device_tools_cross_platform`, `device_ui_tools`,
    # `device_locating_policy`), which live beside the devices they drive
    # rather than under `test/features/mcp`. The tool schemas golden is the
    # one golden outside the folder that reaches the package: the device tools
    # are served over its types.
    app  = @('test/features/devices',
             'test/features/mcp/tool_schemas_golden_test.dart')
    owns = @('lib/src/features/devices', 'test/features/devices')
  }
  terminal_core = @{
    pkg  = 'packages/karmashala_terminal_core'
    # A Flutter package: `xterm2`'s buffer types and `Color` are the
    # vocabulary, so its own half runs under `flutter test`.
    flutter = $true
    # `test/features/terminal` whole: what is left in it is the app's half —
    # the instance, the recorders, the controllers and the panel — plus the
    # three goldens outside it whose import closure reaches the package: the
    # workbench tree (the shell lays out `PaneLayout`), the tool schemas (the
    # terminal and snippet tools are served over `TerminalProfile`) and the
    # session launches (the launcher builds its argv from a launch context).
    app  = @('test/features/terminal',
             'test/app/shell/workbench_tree_golden_test.dart',
             'test/features/mcp/tool_schemas_golden_test.dart',
             'test/features/sessions/session_launch_golden_test.dart')
    owns = @('lib/src/features/terminal', 'test/features/terminal')
  }
  session = @{
    pkg  = 'packages/karmashala_session'
    # `test/features/sessions` whole: what is left in it is the app's half —
    # the launcher and its policies, the DAOs, the providers, the chat and
    # transcript views and the panels — plus the session launches golden,
    # which sits inside it. Three goldens outside it reach the package: the
    # workbench tree (the shell lays out session rows), the tool schemas (the
    # session, decision and workspace tools are served over its types) and the
    # bound frames (the phone is sent `Session` and `SessionStatus`).
    app  = @('test/features/sessions',
             'test/app/shell/workbench_tree_golden_test.dart',
             'test/features/mcp/tool_schemas_golden_test.dart',
             'test/features/remote/bound_frames_golden_test.dart')
    owns = @('lib/src/features/sessions', 'test/features/sessions')
  }
  mcp = @{
    pkg  = 'packages/karmashala_mcp'
    # `test/features/mcp` whole: what is left in it is the app's half — the
    # twenty handlers that serve the app's own types through the injected
    # container, the control server that assembles the served surface, and its
    # hardening — including the tool schemas golden, which pins that whole
    # surface and so cannot leave the app. Four suites outside the folder reach
    # the package: the two system-health ones (the bridge is probed, §19), the
    # skill installer (the skills are the package's), the handshake-file
    # permissions the vault locks its key with, and the settings section that
    # counts the catalogue.
    app  = @('test/features/mcp',
             'test/features/environments/system_health_test.dart',
             'test/features/environments/system_health_dialog_test.dart',
             'test/features/agents/agent_skill_installation_service_test.dart',
             'test/features/env_secrets/env_vault_test.dart',
             'test/features/env_secrets/local_key_cipher_test.dart',
             'test/features/settings/agent_tools_section_test.dart')
    owns = @('lib/src/features/mcp', 'test/features/mcp')
  }
  ssh = @{
    pkg  = 'packages/karmashala_ssh'
    # `test/features/ssh` whole: what is left in it is the app's half — the
    # three DAOs, the suites that bind the verifier, the connection and the
    # runner to a real database, the providers, the sections and dialogs, and
    # the two `live-ssh` suites (excluded by tag here as everywhere). Six
    # suites outside the folder import the package: the host and SSH panes,
    # the environments and session-host sections, the shutdown teardown and
    # the two window matrices. No golden is listed: every one of the six
    # reaches the package mechanically, through `command_runner_providers`,
    # but not one pins a value the package owns — the `ssh` strings in the
    # tool schemas, bound frames and session launches goldens are all
    # `agent_cli`'s `ExecutionEnvironment` and `environmentLabel`.
    app  = @('test/features/ssh',
             'test/terminal/host_pane_test.dart',
             'test/terminal/host_pane_link_test.dart',
             'test/terminal/local_host_access_test.dart',
             'test/terminal/ssh_host_pane_test.dart',
             'test/terminal/ssh_pane_wiring_test.dart',
             'test/features/environments/environments_section_test.dart',
             'test/features/settings/session_host_status_test.dart',
             'test/core/lifecycle/shutdown_teardown_test.dart',
             'test/app/dialog_window_matrix_test.dart',
             'test/app/minimum_window_matrix_test.dart')
    owns = @('lib/src/features/ssh', 'test/features/ssh')
  }
  ui = @{
    pkg  = 'packages/karmashala_ui'
    # A Flutter package through and through: it is widgets, a `ThemeData` and
    # the tokens under both, so its own half runs under `flutter test`.
    flutter = $true
    # Thirty units import the tokens and the glyph table, so "the suites that
    # exercise it" would be the whole gate and prove nothing faster. Mapped
    # instead: the two folders the app kept of what left — the token-debt
    # sweep, which now reads the package's `lib/` as well as the app's, and
    # the status dot, which stays for the window matrix it is pumped through
    # — the four suites whose *subject* is a package widget (the pane header,
    # the UI text scale, the matrix's own guard and the context-menu design),
    # and the two goldens that pin a type name this package owns:
    # `StatusDot` in the workbench tree, `DesktopMenuItem` and
    # `DesktopMenuDivider` in the terminal panel. The device pane, tool
    # schemas, bound frames and session launches goldens reach the package
    # mechanically but record nothing of its.
    app  = @('test/app/theme', 'test/app/widgets',
             'test/app/ui_text_scale_test.dart',
             'test/app/shell/pane_header_test.dart',
             'test/app/shell/workbench_tree_golden_test.dart',
             'test/support/window_matrix_test.dart',
             'test/terminal/context_menu_design_test.dart',
             'test/features/terminal/terminal_panel_tree_golden_test.dart')
    # Nothing under `lib/` is this package's alone: `app/theme`, `app/widgets`
    # and `core/widgets` left whole and the directories are gone.
    owns = @('test/app/theme', 'test/app/widgets')
  }
  remote = @{
    pkg  = 'packages/karmashala_remote'
    # Both folders whole: what is left in them is the app's half of the link —
    # the DAOs, the host service, the providers and the phone's screens — and
    # `bound_frames_golden_test.dart` sits inside the first.
    app  = @('test/features/remote', 'test/features/companion')
    owns = @('lib/src/features/remote', 'lib/src/features/companion',
             'test/features/remote', 'test/features/companion')
  }
}

# A change here changes what every suite resolves or how it runs, so nothing
# smaller than the full gate is honest about it.
$fullGateTriggers = @(
  'pubspec.yaml', 'pubspec.lock', 'dart_test.yaml', 'analysis_options.yaml',
  'lib/main.dart', 'lib/src/app/', 'lib/src/core/database/',
  'lib/src/core/lifecycle/', 'test/support/', 'tool/gate.ps1'
)

foreach ($name in (Get-ChildItem Env: | Where-Object { $_.Name -like 'KARMASHALA_WRITE_*' })) {
  Write-Host "refusing to run: $($name.Name) is set, and a gate that rewrites its own goldens proves nothing." -ForegroundColor Red
  exit 2
}

$failed = @()

function Invoke-Gate {
  param([string]$Label, [string]$Exe, [string[]]$GateArgs)

  $log = Join-Path $gateDir "$Label.txt"
  Write-Host "=== $Label ===" -ForegroundColor Cyan
  Write-Host "    $Exe $($GateArgs -join ' ')"
  $started = Get-Date
  # Redirected to a file, then read back: the exit code must come from the
  # command itself and not from whatever would have been on the other end of a
  # pipe.
  & $Exe @GateArgs > $log 2>&1
  $code = $LASTEXITCODE
  $elapsed = (Get-Date) - $started

  $verdict = Select-String -Path $log -Pattern '^(All tests passed|Some tests failed|No tests ran)' |
    Select-Object -Last 1
  $counts = Select-String -Path $log -Pattern '^\s*\d+:\d+\s+\+\d+' | Select-Object -Last 1
  if ($counts) { Write-Host "    $($counts.Line.Trim())" }
  if ($verdict) { Write-Host "    $($verdict.Line.Trim())" }
  Write-Host ("    exit={0}  {1:mm\:ss}  -> {2}" -f $code, $elapsed, $log)
  if ($code -ne 0) { $script:failed += $Label }
  return $code
}

function Invoke-PackageGate {
  param([string]$Key)

  if (-not $map.Contains($Key)) {
    Write-Host "unknown package '$Key'. Known: $($map.Keys -join ', ')" -ForegroundColor Red
    exit 2
  }
  $entry = $map[$Key]
  $pkgDir = Join-Path $root ($entry.pkg -replace '/', '\')

  if (Test-Path $pkgDir) {
    Push-Location $pkgDir
    try {
      $pkgExe = if ($entry['flutter']) { $flutter } else { $dart }
      Invoke-Gate -Label "$Key-pkg" -Exe $pkgExe -GateArgs @('test', '--reporter', 'expanded') | Out-Null
    } finally {
      Pop-Location
    }
  } else {
    Write-Host "=== $Key-pkg ===" -ForegroundColor DarkYellow
    Write-Host "    $($entry.pkg) is not extracted yet; running the app half only."
  }

  # `test/terminal/perf/**` is frozen: -Full only, never a package run.
  $appPaths = @($entry.app |
    Where-Object { -not $_.StartsWith('test/terminal/perf') } |
    Where-Object { Test-Path (Join-Path $root ($_ -replace '/', '\')) })
  if ($appPaths.Count -eq 0) {
    Write-Host "    no app suites mapped for '$Key'." -ForegroundColor DarkYellow
    return
  }
  $flutterArgs = @('test') + $appPaths + @(
    '--exclude-tags=live-ssh,live-wsl,cost', '--reporter', 'expanded'
  )
  Invoke-Gate -Label "$Key-app" -Exe $flutter -GateArgs $flutterArgs | Out-Null
}

function Get-ChangedPackages {
  $files = @()
  $base = & git merge-base HEAD main 2>$null
  if ($LASTEXITCODE -eq 0 -and $base) { $files += & git diff --name-only $base }
  $files += & git diff --name-only
  $files += & git diff --name-only --cached
  $files = $files | Where-Object { $_ } | ForEach-Object { $_ -replace '\\', '/' } | Sort-Object -Unique

  if ($files.Count -eq 0) { return @{ packages = @(); full = $false; files = @() } }
  foreach ($f in $files) {
    foreach ($t in $fullGateTriggers) {
      if ($f -eq $t -or $f.StartsWith($t)) { return @{ packages = @(); full = $true; files = $files } }
    }
  }

  $hit = New-Object System.Collections.Generic.List[string]
  foreach ($f in $files) {
    foreach ($key in $map.Keys) {
      $e = $map[$key]
      if ($f.StartsWith(($e.pkg + '/'))) { if (-not $hit.Contains($key)) { $hit.Add($key) }; continue }
      foreach ($o in $e.owns) {
        if ($f.StartsWith(($o + '/')) -or $f -eq $o) { if (-not $hit.Contains($key)) { $hit.Add($key) } }
      }
    }
  }
  return @{ packages = $hit; full = $false; files = $files }
}

if ($Full) {
  Invoke-Gate -Label 'full' -Exe $flutter -GateArgs @(
    'test', '--exclude-tags=live-ssh,live-wsl', '--reporter', 'expanded'
  ) | Out-Null
} elseif ($Package) {
  Invoke-PackageGate -Key $Package
} elseif ($Changed) {
  # Not `$changed`: PowerShell variable names are case-insensitive, so that
  # name is the `[switch]` parameter above and assigning a hashtable to it
  # throws before the first suite runs.
  $selection = Get-ChangedPackages
  if ($selection.files.Count -eq 0) {
    Write-Host 'nothing changed against main; no gate to run.'
    exit 0
  }
  if ($selection.full) {
    Write-Host 'a change reaches the app shell, a pubspec or the test harness: running the full gate.'
    Invoke-Gate -Label 'full' -Exe $flutter -GateArgs @(
      'test', '--exclude-tags=live-ssh,live-wsl', '--reporter', 'expanded'
    ) | Out-Null
  } elseif ($selection.packages.Count -eq 0) {
    # App-only folders map to their own mirror: lib/src/features/<f> -> test/features/<f>.
    $mirrors = @()
    foreach ($f in $selection.files) {
      if ($f -match '^(?:lib/src|test)/features/([^/]+)/') {
        $m = "test/features/$($Matches[1])"
        if ((Test-Path (Join-Path $root ($m -replace '/', '\'))) -and ($mirrors -notcontains $m)) { $mirrors += $m }
      }
    }
    if ($mirrors.Count -eq 0) {
      Write-Host 'changed files map to no package and no mirror folder: running the full gate.'
      Invoke-Gate -Label 'full' -Exe $flutter -GateArgs @(
        'test', '--exclude-tags=live-ssh,live-wsl', '--reporter', 'expanded'
      ) | Out-Null
    } else {
      Write-Host "app-only change; mirrors: $($mirrors -join ', ')"
      Invoke-Gate -Label 'mirrors' -Exe $flutter -GateArgs (
        @('test') + $mirrors + @('--exclude-tags=live-ssh,live-wsl,cost', '--reporter', 'expanded')
      ) | Out-Null
    }
  } else {
    Write-Host "changed packages: $($selection.packages -join ', ')"
    foreach ($key in $selection.packages) { Invoke-PackageGate -Key $key }
  }
} else {
  Write-Host 'usage: gate.ps1 -Package <name> | -Changed | -Full'
  Write-Host "packages: $($map.Keys -join ', ')"
  exit 2
}

if ($failed.Count -gt 0) {
  Write-Host "FAILED: $($failed -join ', ')" -ForegroundColor Red
  exit 1
}
Write-Host 'gate green.' -ForegroundColor Green
exit 0
