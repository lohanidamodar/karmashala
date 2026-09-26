# Drives the COM file dialog that `file_picker_probe.dart` opens.
#
#   powershell -ExecutionPolicy Bypass -File tool\verification\pick_probe_file.ps1
#
# A modal Win32 dialog is not a Flutter surface, so the probe's `tester` cannot
# dismiss it. This confirms a real selection for the first dialog and cancels
# the second, appending what it did to the same log the probe writes, so one
# file tells the whole story in order.
#
# The dialog is found through UI Automation, filtered to a window of class
# #32770 owned by a karmashala.exe. Nothing is typed or invoked until that
# check passes: stray keystrokes would land in whatever the owner has open.
#
# The file it picks is a *public* key. The probe only reads `file.path`, and
# pointing the dialog at the real .ssh folder is what makes the run faithful to
# the report without putting a private key anywhere.
param(
  [string]$Log = 'C:\Users\dlohani\karmashala-picker-probe.log',
  [string]$Pick = 'C:\Users\dlohani\.ssh\id_ed25519.pub',
  [int]$WaitSeconds = 180,
  # Only a karmashala.exe launched from this worktree is ever touched. The
  # owner's installed instance has the same process name and may legitimately
  # have a dialog of its own open; driving that one would be someone else's
  # keystrokes.
  [string]$OnlyUnder = 'karmashala-app-filepicker'
)

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$AE = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]

function Say {
  param([string]$Line)
  $stamped = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fff') + ' driver: ' + $Line
  Write-Host $stamped
  Add-Content -LiteralPath $Log -Value $stamped -Encoding UTF8
}

# A top-level common dialog owned by a karmashala.exe, or $null.
function Get-PickerDialog {
  $ours = @()
  Get-Process -Name karmashala -ErrorAction SilentlyContinue | ForEach-Object {
    $path = ''
    try { $path = $_.Path } catch { $path = '' }
    if ($path -like ('*' + $OnlyUnder + '*')) { $ours += $_.Id }
  }
  if ($ours.Count -eq 0) { return $null }
  $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, '#32770')
  $found = $AE::RootElement.FindAll($Scope::Children, $cond)
  foreach ($w in $found) {
    if ($ours -contains $w.Current.ProcessId) { return $w }
  }
  return $null
}

# Puts $Pick in the dialog's file-name box and presses its default button.
function Confirm-Selection {
  param($Dialog)
  $editCond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)
  $edit = $Dialog.FindFirst($Scope::Descendants, $editCond)
  if ($null -eq $edit) {
    Say 'no file-name edit found in the dialog; cancelling instead'
    return $false
  }
  $value = $edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
  $value.SetValue($Pick)
  Say ('set the file name to ' + $Pick)
  $btnCond = New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, '1')
  $btn = $Dialog.FindFirst($Scope::Descendants, $btnCond)
  if ($null -eq $btn) {
    Say 'no default button found; cancelling instead'
    return $false
  }
  $invoke = $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
  Say ('invoking ' + $btn.Current.Name)
  $invoke.Invoke()
  return $true
}

function Cancel-Dialog {
  param($Dialog)
  $btnCond = New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, '2')
  $btn = $Dialog.FindFirst($Scope::Descendants, $btnCond)
  if ($null -eq $btn) {
    Say 'no cancel button found; leaving the dialog up'
    return
  }
  $invoke = $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
  Say ('invoking ' + $btn.Current.Name)
  $invoke.Invoke()
}

Say ('started; waiting up to ' + $WaitSeconds + ' s for a dialog')
if (Test-Path -LiteralPath $Pick) {
  Say ('will confirm the first dialog with ' + $Pick)
} else {
  Say ($Pick + ' does not exist; every dialog will be cancelled instead')
  $Pick = ''
}

$deadline = (Get-Date).AddSeconds($WaitSeconds)
$round = 0
while ((Get-Date) -lt $deadline) {
  if ($round -ge 2) { break }
  $dlg = Get-PickerDialog
  if ($null -eq $dlg) {
    Start-Sleep -Milliseconds 400
    continue
  }
  $round = $round + 1
  Say ('round ' + $round + ': dialog up pid=' + $dlg.Current.ProcessId + ' name=' + $dlg.Current.Name)
  Start-Sleep -Milliseconds 900
  $confirmed = $false
  if ($round -eq 1 -and $Pick -ne '') {
    $confirmed = Confirm-Selection -Dialog $dlg
  }
  if (-not $confirmed) {
    Cancel-Dialog -Dialog $dlg
  }
  $gone = (Get-Date).AddSeconds(20)
  while ((Get-Date) -lt $gone) {
    if ($null -eq (Get-PickerDialog)) { break }
    Start-Sleep -Milliseconds 300
  }
  Say ('round ' + $round + ': dismissed')
  Start-Sleep -Seconds 3
}
Say ('finished after ' + $round + ' round(s)')
