/// Shell-side OSC 133 injection.
///
/// Everything here is pure: it produces the text of a script and the encoding
/// of it, and never touches the filesystem or the user's configuration.
/// Injection happens **only at launch**, so nothing is left behind.
library;

import 'dart:convert';

import 'terminal_profile.dart';

/// Whether this app can emit OSC 133 markers from [shell] safely: PowerShell
/// and WSL only.
///
/// **`cmd.exe` is refused permanently, and it is a measurement.** `C` has no
/// hook to come from — `cmd` has nothing between reading a command and running
/// it — and `PROMPT` freezes `%ERRORLEVEL%` when it is set, so `D;<code>` is
/// unreachable too. A `cmd.exe` pane's exit code is genuinely unknown, and
/// `terminal_run` says so rather than reporting a zero.
bool shellSupportsIntegration(TerminalShell shell) =>
    shell == TerminalShell.powerShell || shell == TerminalShell.wsl;

/// Encodes [script] the way `powershell.exe -EncodedCommand` expects: base64 of
/// UTF-16LE. Used instead of `-Command` so Windows command-line quoting is
/// removed from the problem entirely.
String encodePowerShellCommand(String script) {
  final bytes = <int>[];
  for (final unit in script.codeUnits) {
    bytes
      ..add(unit & 0xff)
      ..add(unit >> 8);
  }
  return base64Encode(bytes);
}

/// The PowerShell OSC 133 (and OSC 7) bootstrap.
///
/// It rests on `-EncodedCommand` running **after** the user's profiles, so
/// `$function:prompt` is already their final prompt: we wrap it, and never
/// touch `$PROFILE`. The guards, each tested against a real PowerShell 5.1:
/// `$?` is captured as the literal first statement, `$LASTEXITCODE` and `$?`
/// are put back before the user's prompt runs, `Set-StrictMode -Off` in case a
/// profile set `-Version Latest` globally, and `C` wraps
/// `PSConsoleHostReadLine` rather than binding Enter. Exit codes are best
/// effort — `$LASTEXITCODE` is real only for native executables — but the
/// failed/succeeded flag always is.
String powerShellIntegrationScript() => r'''
# Karmashala OSC 133 shell integration.
# Injected at launch with -EncodedCommand, which PowerShell runs after profiles
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
