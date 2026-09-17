/// Shell-side OSC 133 injection: script text only. Injection happens **only at
/// launch**, so nothing is left on the user's machine.
library;

import 'terminal_profile.dart';

/// Whether this app can emit OSC 133 markers from [shell]: PowerShell and WSL.
/// **`cmd.exe` is refused permanently** — it has no hook to emit `C` from.
bool shellSupportsIntegration(TerminalShell shell) =>
    shell == TerminalShell.powerShell || shell == TerminalShell.wsl;

/// The PowerShell OSC 133 (and OSC 7) bootstrap. It rests on `-Command` running
/// **after** the user's profiles, so it wraps their final prompt. Handed over
/// as a plain, readable `-Command` — never `-EncodedCommand`, which behavioural
/// antivirus scores as a dropper signal — so it must stay printable ASCII.
String powerShellIntegrationScript() => r'''
# Karmashala OSC 133 shell integration.
# Injected at launch with -Command, which PowerShell runs after profiles
# have loaded. Nothing is written to the user's profile, or anywhere on disk.
if ($ExecutionContext.SessionState.LanguageMode -eq 'FullLanguage' -and -not (Test-Path variable:global:__CgOsc133)) {
  try {
    $Global:__CgOsc133 = @{
      OriginalPrompt   = $function:prompt
      OriginalReadLine = $function:PSConsoleHostReadLine
      SeenPrompt       = $false
      Esc              = [char]27
      Bel              = [char]7
    }

    function Global:prompt {
      $__cgOk = $?
      $__cgLast = $global:LASTEXITCODE
      Set-StrictMode -Off
      $e = $Global:__CgOsc133.Esc
      $b = $Global:__CgOsc133.Bel
      $out = ''
      if ($Global:__CgOsc133.SeenPrompt) {
        $code = 0
        if (-not $__cgOk) {
          if ($null -ne $__cgLast -and $__cgLast -ne 0) { $code = $__cgLast } else { $code = 1 }
        }
        $out += "$e]133;D;$code$b"
      }
      $Global:__CgOsc133.SeenPrompt = $true
      $out += "$e]133;A$b"
      try {
        if ($PWD.Provider.Name -eq 'FileSystem') {
          $out += "$e]7;$(([uri]$PWD.ProviderPath).AbsoluteUri)$b"
        }
      } catch {
        # A location that will not cast to a URI is not worth a broken prompt.
      }
      $global:LASTEXITCODE = $__cgLast
      if (-not $__cgOk) { Write-Error 'failure' -ea ignore }
      $out += [string]($Global:__CgOsc133.OriginalPrompt.Invoke())
      $out += "$e]133;B$b"
      $global:LASTEXITCODE = $__cgLast
      $out
    }

    if ($null -ne $Global:__CgOsc133.OriginalReadLine -and $null -ne (Get-Module -Name PSReadLine)) {
      function Global:PSConsoleHostReadLine {
        $__cgLine = $Global:__CgOsc133.OriginalReadLine.Invoke()
        [Console]::Write("$($Global:__CgOsc133.Esc)]133;C$($Global:__CgOsc133.Bel)")
        return $__cgLine
      }
    }
  } catch {
    # Shell integration must never break the shell.
  }
}
''';
