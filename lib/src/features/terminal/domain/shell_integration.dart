/// Shell-side OSC 133 injection.
///
/// Everything here is pure: it produces the text of a script and the encoding
/// of that script, and never touches the filesystem, a process or the user's
/// configuration. Injection happens **only at launch**, so nothing persists on
/// the user's machine and nothing is left behind if the app is removed.
library;

import 'dart:convert';

import 'terminal_profile.dart';

/// Whether this app can emit OSC 133 markers from [shell] safely.
///
/// PowerShell and WSL. A WSL pane is instrumented by the payload its launch
/// already carries ([wslIntegrationBootstrap]); the probe that kept it parked
/// is gone, because the payload writes the rc file it then reads and every
/// failing path falls back to the plain login shell.
///
/// **`cmd.exe` is skipped permanently, and this is the measurement.** Windows
/// 10.0.26200, 2026-09-09:
///
/// * `prompt $E]133;A$E\` works — `ESC ] 1 3 3 ; A ESC \` is on the wire
///   before every prompt, so `A` (and a fixed `B`) are within reach;
/// * `C` is not. `cmd` has no hook between reading a command and running it —
///   no `PS0`, no `preexec`, no `DEBUG` trap — and `AutoRun` fires once per
///   shell, not once per command. Without `C` a block is discarded by
///   [CommandBlockTracker], so `A` alone buys nothing;
/// * `D;<code>` is not either. `PROMPT` expands `$`-codes only: `%ERRORLEVEL%`
///   is substituted once when `prompt` is *set* and then frozen — measured as
///   `[D=0]` in front of a failing command and the one after it — and
///   `!ERRORLEVEL!` with delayed expansion on is frozen the same way.
///
/// So a `cmd.exe` pane's exit code is genuinely unknown, and `terminal_run`
/// says so rather than reporting a zero it did not receive.
///
/// A distribution whose login shell is neither bash nor zsh (fish, a bare `sh`)
/// launches exactly as it did before and simply emits nothing. The pane still
/// carries a recorder, and `markersSeen` is what reports the truth about it —
/// the alternative is a probe on the launch path answering a question only the
/// far side can answer.
bool shellSupportsIntegration(TerminalShell shell) =>
    shell == TerminalShell.powerShell || shell == TerminalShell.wsl;

/// Encodes [script] the way `powershell.exe -EncodedCommand` expects: base64 of
/// UTF-16LE.
///
/// Used instead of `-Command` so Windows command-line quoting is removed from
/// the problem entirely — there is no escaping bug left to have.
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
/// The mechanism rests on one property of PowerShell's own startup order:
/// `-EncodedCommand` runs **after** the user's profiles have loaded, so
/// `$function:prompt` is already their *final* prompt, whatever built it
/// (oh-my-posh, starship, a hand-written one). We wrap it; we never replace it,
/// and we never read or write `$PROFILE`.
///
/// Every guard in here exists for a reason that was tested against a real
/// PowerShell 5.1 before being written down:
///
/// * `$?` is captured as the literal first statement — any expression before it
///   clobbers the only reliable did-it-fail signal PowerShell has.
/// * `$LASTEXITCODE` is put back before the user's prompt runs, so a prompt that
///   renders the last exit code still shows the real one.
/// * `$?` is re-falsified with a discarded `Write-Error`, so a prompt that
///   renders a failure indicator still works — by the time we call it, our own
///   statements have made `$?` true.
/// * `Set-StrictMode -Off` because a user profile may have set
///   `-Version Latest` globally, which would make our own lookups fatal.
/// * `C` comes from wrapping `PSConsoleHostReadLine` rather than binding Enter,
///   which leaves every PSReadLine key handler — including the user's — alone.
/// * OSC 7 rides along in the same prompt function, because the prompt is the
///   only moment PowerShell reliably tells anyone it has moved. `$PWD` is a
///   *PowerShell* location, so it is `ProviderPath` that is reported (the host
///   path, not `Registry::HKLM\SOFTWARE`), guarded on the provider actually
///   being the filesystem; `[uri]` builds the `file://` form and does the
///   percent-encoding, so a directory with a space in it survives. Without
///   this, only a shell that happens to emit OSC 7 by itself ever gets a live
///   directory — and PowerShell, the default profile, does not.
///
/// Exit codes are best effort. `$?` always answers *did it fail*;
/// `$LASTEXITCODE` only carries a real code for native executables, so a failing
/// cmdlet straight after a failing native command inherits the stale code. The
/// failed/succeeded flag, which is what the UI marks, is always right.
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
