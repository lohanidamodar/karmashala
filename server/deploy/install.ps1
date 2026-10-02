<#
.SYNOPSIS
  Installs the Karmashala server, a relay, or both on this Windows machine, for
  this user, started at sign-in. No administrator rights needed.

.DESCRIPTION
  Runs straight from a release:

    irm https://github.com/lohanidamodar/karmashala/releases/latest/download/install.ps1 | iex

  or, with options, from a downloaded copy:

    .\install.ps1 -WithRelay -HostAddress my.box.example

  With no -Bundle, the Windows server bundle is downloaded from the latest
  release (or -Version). The bundle goes under %LOCALAPPDATA%\Karmashala\server,
  a `karmashala_host` command goes on this user's PATH, and each service is a
  scheduled task that starts it, hidden, when this user signs in: it runs as
  this user, so the agents it starts use this user's sign-ins and PATH. It runs
  while this user is signed in; a locked screen is fine.

  On a machine where the Karmashala desktop app runs, the app's server already
  is this machine's server; this installer is for running one without it.

.PARAMETER Relay
  Install only a relay: a meeting point for a server and its clients when
  neither can dial the other.
.PARAMETER WithRelay
  Install the server and a relay, the server using this relay.
.PARAMETER Version
  The release to download (default: the latest).
.PARAMETER Bundle
  A server bundle to install instead: the `bundle` folder `dart build cli`
  produced, or a .zip of its contents.
.PARAMETER HostAddress
  The address clients reach this machine at (default: its first non-loopback
  IPv4 address).
.PARAMETER Lan
  Serve clients on this network directly: listen on every interface and
  announce on the LAN beacon.
.PARAMETER Bind
  Where the phone listener binds (default 127.0.0.1).
.PARAMETER Port
  The phone listener's port (default 47820).
.PARAMETER RelayUrl
  A relay elsewhere for the server to use.
.PARAMETER RelayToken
  That relay's access token.
.PARAMETER RelayPort
  The port a relay installed here listens on (default 8787).
.PARAMETER Name
  What clients call this server (default: the computer name).
.PARAMETER DataDir
  The store and server.json (default ~\.karmashala).
.PARAMETER ForceConfig
  Replace an existing server.json with these options.
.PARAMETER NoPair
  Do not open a pairing window at the end.
.PARAMETER Uninstall
  Remove the tasks, the bundle and the command. The store and every pairing are
  kept unless -Purge.
.PARAMETER Purge
  With -Uninstall, also delete the data directory.
#>
# A function, so `irm … | iex` and `& ([scriptblock]::Create((irm …))) -WithRelay`
# run it inside the caller's session without an `exit` closing that session.
function Install-Karmashala {
[CmdletBinding()]
param(
  [switch]$Relay,
  [switch]$WithRelay,
  [string]$Version,
  [string]$Bundle,
  [string]$HostAddress,
  [switch]$Lan,
  [string]$Bind,
  [int]$Port = 47820,
  [string]$RelayUrl,
  [string]$RelayToken,
  [int]$RelayPort = 8787,
  [string]$Name,
  [string]$DataDir = (Join-Path $HOME '.karmashala'),
  [switch]$ForceConfig,
  [switch]$NoPair,
  [switch]$Uninstall,
  [switch]$Purge
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repo = if ($env:KARMASHALA_REPO) { $env:KARMASHALA_REPO } else { 'lohanidamodar/karmashala' }
$Prefix = Join-Path $env:LOCALAPPDATA 'Karmashala\server'
$Current = Join-Path $Prefix 'current'
$Bin = Join-Path $Current 'bin\karmashala_host.exe'
$CommandDir = Join-Path $env:LOCALAPPDATA 'Karmashala\bin'
$ServerTask = 'Karmashala Server'
$RelayTask = 'Karmashala Relay'
$RelayTokenFile = Join-Path $DataDir 'relay-token'
$RelayPidFile = Join-Path $DataDir 'relay.pid'

function Say([string]$Text) { Write-Host $Text }
function Fail([string]$Text) { throw "install.ps1: $Text" }

# Every call to a binary goes through these two. Windows PowerShell turns a
# native program's stderr into a terminating error under 'Stop', and the binary
# answers "no host yet" on stderr while the server starts.
function Invoke-Native([string]$Program, [string[]]$Arguments, [switch]$Show) {
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    if ($Show) { & $Program @Arguments 2>&1 | Out-Host } else { & $Program @Arguments *> $null }
  } finally {
    $ErrorActionPreference = $previous
  }
  return $LASTEXITCODE
}

# The lines the binary prints, stderr left out.
function Read-Native([string]$Program, [string[]]$Arguments) {
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { return @(& $Program @Arguments 2>$null) } finally { $ErrorActionPreference = $previous }
}

# Runs the installed binary, showing what it says; answers its exit code.
function Invoke-Host([string[]]$Arguments) { return Invoke-Native $Bin $Arguments -Show }

function Test-HostRunning {
  if (-not (Test-Path $Bin)) { return $false }
  return (Invoke-Native $Bin @('list')) -eq 0
}

function Get-HeldSessions {
  return @(Read-Native $Bin @('list') | Select-Object -Skip 1 |
    Where-Object { ($_ -split '\s+')[3] -eq 'running' }).Count
}

function Remove-Tasks {
  foreach ($task in $ServerTask, $RelayTask) {
    if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) {
      Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
      Unregister-ScheduledTask -TaskName $task -Confirm:$false
      Say "Removed the '$task' task."
    }
  }
}

# Stopping a task ends conhost, not the program it started, and `stop` reaches
# only the server. What is still running from this install is ended, so its
# files can go; nothing outside $Prefix is touched.
function Stop-InstalledProcesses {
  $ours = Get-Process -Name karmashala_host -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase) }
  if ($ours) {
    $ours | Stop-Process -Force
    $ours | Wait-Process -Timeout 15 -ErrorAction SilentlyContinue
  }
}

if ($Uninstall) {
  if (Test-HostRunning) {
    $held = Get-HeldSessions
    if ($held -gt 0) { Fail "the server is running $held session(s); end them first (karmashala_host list / end <id>)" }
    Invoke-Native $Bin @('stop') | Out-Null
  }
  Remove-Tasks
  Stop-InstalledProcesses
  if (Test-Path $Prefix) { Remove-Item -Recurse -Force $Prefix; Say "Removed $Prefix." }
  $shim = Join-Path $CommandDir 'karmashala_host.cmd'
  if (Test-Path $shim) { Remove-Item -Force $shim }
  if ($Purge -and (Test-Path $DataDir)) {
    Remove-Item -Recurse -Force $DataDir
    Say "Deleted $DataDir."
  } else {
    Say "Kept $DataDir (the store and pairings; -Purge deletes it)."
  }
  return
}

$WantServer = -not $Relay
$WantRelay = $Relay -or $WithRelay
if ($WantRelay -and $RelayUrl) { Fail '-RelayUrl names a relay elsewhere; -Relay and -WithRelay install one here' }
if (-not [Environment]::Is64BitOperatingSystem) { Fail 'the server is built for 64-bit Windows only' }

# The address clients reach this machine at: given, or the first non-loopback
# one, which is right on a LAN and wrong behind NAT.
$HostGuessed = $false
if (-not $HostAddress) {
  $HostAddress = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and $_.PrefixOrigin -ne 'WellKnown' } |
    Sort-Object -Property InterfaceMetric | Select-Object -First 1 -ExpandProperty IPAddress
  if (-not $HostAddress) { $HostAddress = '127.0.0.1' }
  $HostGuessed = $true
}

$Work = Join-Path ([IO.Path]::GetTempPath()) ("karmashala-install-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Work | Out-Null
try {
  # 1. The bundle.
  $Stage = Join-Path $Work 'bundle'
  if (-not $Bundle) {
    if ($Version) {
      $tag = 'v' + $Version.TrimStart('v')
    } else {
      # The latest release's tag, from where /releases/latest redirects to.
      $request = [Net.WebRequest]::Create("https://github.com/$Repo/releases/latest")
      $request.AllowAutoRedirect = $false
      $response = $request.GetResponse()
      $tag = ($response.Headers['Location'] -split '/')[-1]
      $response.Close()
      if ($tag -notlike 'v*') { Fail "could not find the latest release of $Repo" }
    }
    $Bundle = "https://github.com/$Repo/releases/download/$tag/karmashala_host-$($tag.TrimStart('v'))-windows-x64.zip"
  }
  if ($Bundle -match '^https?://') {
    Say "Downloading $Bundle"
    $zip = Join-Path $Work 'bundle.zip'
    try { Invoke-WebRequest -Uri $Bundle -OutFile $zip -UseBasicParsing } catch { Fail "could not download $Bundle" }
    Expand-Archive -Path $zip -DestinationPath $Stage
  } elseif ($Bundle -like '*.zip') {
    if (-not (Test-Path $Bundle)) { Fail "$Bundle is not a file" }
    Expand-Archive -Path $Bundle -DestinationPath $Stage
  } else {
    if (-not (Test-Path $Bundle -PathType Container)) { Fail "$Bundle is neither a folder, a .zip nor a URL" }
    Copy-Item -Recurse -Path (Join-Path $Bundle '*') -Destination (New-Item -ItemType Directory -Path $Stage)
  }
  if (-not (Test-Path (Join-Path $Stage 'bin\karmashala_host.exe')) -and (Test-Path (Join-Path $Stage 'bundle\bin\karmashala_host.exe'))) {
    $Stage = Join-Path $Stage 'bundle'
  }
  $StageBin = Join-Path $Stage 'bin\karmashala_host.exe'
  if (-not (Test-Path $StageBin)) { Fail "no bin\karmashala_host.exe in $Bundle" }

  # 2. Proven here before anything is replaced. A relay alone needs neither a
  # terminal nor a store.
  if ((Invoke-Native $StageBin @('version')) -ne 0) { Fail 'the bundle does not run on this machine' }
  if ($WantServer) {
    foreach ($probe in 'probe-pty', 'probe-store') {
      if ((Invoke-Native $StageBin @($probe)) -ne 0) {
        Invoke-Native $StageBin @($probe) -Show | Out-Null
        Fail "the bundle failed $probe here"
      }
    }
  }
  Say ("Bundle: " + ((Read-Native $StageBin @('version')) -join ' '))

  # 3. Installed side by side with any earlier one; `current` is a junction to
  # the live one, which needs no administrator rights.
  $Release = Join-Path $Prefix ('releases\' + (Get-Date -Format 'yyyyMMddHHmmss'))
  New-Item -ItemType Directory -Path $Release -Force | Out-Null
  Copy-Item -Recurse -Path (Join-Path $Stage '*') -Destination $Release
  if (Test-Path $Current) { (Get-Item $Current).Delete() }
  New-Item -ItemType Junction -Path $Current -Target $Release | Out-Null
  Say "Installed to $Release"
} finally {
  Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
}

# A command on this user's PATH. A shim, not a copy: the binary finds its lib\
# next to where it really is.
New-Item -ItemType Directory -Path $CommandDir -Force | Out-Null
Set-Content -Path (Join-Path $CommandDir 'karmashala_host.cmd') -Value "@`"$Bin`" %*" -Encoding ASCII
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (($userPath -split ';') -notcontains $CommandDir) {
  [Environment]::SetEnvironmentVariable('Path', (($userPath, $CommandDir) -join ';').Trim(';'), 'User')
  Say 'Added karmashala_host to your PATH (new terminals see it).'
}

# 4. A relay installed here: its token is minted now, so the URL clients use is
# known before anything starts.
if ($WantRelay) {
  New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
  if (-not (Test-Path $RelayTokenFile) -or -not (Get-Content $RelayTokenFile -Raw)) {
    $bytes = New-Object byte[] 30
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $token = [Convert]::ToBase64String($bytes).Replace('+', '-').Replace('/', '_').TrimEnd('=')
    Set-Content -Path $RelayTokenFile -Value $token -NoNewline -Encoding ASCII
  }
  $RelayToken = (Get-Content $RelayTokenFile -Raw).Trim()
  $RelayUrl = "ws://${HostAddress}:$RelayPort"
}

# 5. The server's config, written by the bundle itself and never replaced
# unless asked.
if ($WantServer) {
  $init = @('init', "--data-dir=$DataDir", '--companion', "--companion-port=$Port")
  if ($Lan) { $Bind = '0.0.0.0'; $init += '--beacon' }
  if ($Bind) { $init += "--bind=$Bind" }
  if ($Name) { $init += "--name=$Name" }
  if ($RelayUrl) {
    $init += "--relay=$RelayUrl"
    if ($RelayToken) { $init += "--relay-token=$RelayToken" }
  }
  if ((Test-Path (Join-Path $DataDir 'server.json')) -and -not $ForceConfig) {
    Say "Keeping $DataDir\server.json (-ForceConfig replaces it with these options)."
  } else {
    if ($ForceConfig) { $init += '--force' }
    if ((Invoke-Host $init) -ne 0) { Fail 'karmashala_host init failed' }
  }
}

# 6. A scheduled task per service, started at this user's sign-in, hidden.
function Register-HostTask([string]$TaskName, [string]$Description, [string[]]$Arguments) {
  $quoted = ($Arguments | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
  # conhost --headless runs a console program with no window.
  $action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless `"$Bin`" $quoted"
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew
  $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName $TaskName -Description $Description -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Force | Out-Null
  Start-ScheduledTask -TaskName $TaskName
  Say "Task: '$TaskName' starts at sign-in (Task Scheduler; started now)."
}

if ($WantRelay) {
  # An earlier relay still holds the port; the pid file it wrote names it.
  if (Test-Path $RelayPidFile) {
    $old = (Get-Content $RelayPidFile -Raw).Trim()
    if ($old -match '^\d+$') { Stop-Process -Id ([int]$old) -Force -ErrorAction SilentlyContinue }
  }
  Register-HostTask $RelayTask 'Karmashala relay' @('relay', "--port=$RelayPort", "--token-file=$RelayTokenFile", "--pid-file=$RelayPidFile")
}
if ($WantServer) {
  $ours = Get-ScheduledTask -TaskName $ServerTask -ErrorAction SilentlyContinue
  if ($ours -and $ours.State -eq 'Running') {
    $held = Get-HeldSessions
    if ($held -gt 0) {
      Say "The server is running $held session(s); it was not restarted, so they keep running."
    } else {
      Invoke-Native $Bin @('stop') | Out-Null
      Register-HostTask $ServerTask 'Karmashala server' @('serve', "--data-dir=$DataDir")
    }
  } elseif (Test-HostRunning) {
    Fail 'a karmashala_host is already running for this user (the desktop app''s). On a machine where you use the desktop app, that host already is the server; otherwise stop it (karmashala_host stop) and run this again.'
  } else {
    Register-HostTask $ServerTask 'Karmashala server' @('serve', "--data-dir=$DataDir")
  }
}

Say ''
if ($WantRelay) {
  Say "Relay: $RelayUrl/k/$RelayToken"
  Say "  Clients and servers elsewhere use that URL. Windows asks once to let it through the firewall."
  if ($HostGuessed) { Say "  $HostAddress was guessed; pass -HostAddress with the address clients really reach." }
}
if (-not $WantServer) { return }

# 7. Pair the first client now: the window names whichever route is set up.
if ($NoPair) { Say 'Pair a client later with: karmashala_host pair'; return }
for ($i = 0; $i -lt 30 -and -not (Test-HostRunning); $i++) { Start-Sleep -Seconds 1 }
if (-not (Test-HostRunning)) { Fail "the server did not come up; run `"$Bin`" serve to see why" }
if ($RelayUrl) {
  Say 'Opening a pairing window through the relay. Scan the QR with the Karmashala app,'
  Say 'or add a machine by code. Ctrl+C stops waiting; the server keeps running.'
  Invoke-Host @('pair') | Out-Null
} elseif ($Bind -and $Bind -ne '127.0.0.1') {
  Say "Opening a pairing window at ${HostAddress}:$Port. Scan the QR with the Karmashala app,"
  Say 'or add a machine by address. Ctrl+C stops waiting; the server keeps running.'
  Invoke-Host @('pair', "--address=${HostAddress}:$Port") | Out-Null
} else {
  Say 'The server listens on this machine only, so no client can reach it yet. Run this'
  Say 'again with -Lan (same network), -WithRelay (a relay here) or -RelayUrl <url>'
  Say '(a relay elsewhere), then pair with: karmashala_host pair'
}
}

Install-Karmashala @args
# Reached only on success: the last check of the binary may have answered
# "not yet", which must not read as the install having failed.
$global:LASTEXITCODE = 0
