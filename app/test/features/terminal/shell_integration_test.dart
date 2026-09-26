import 'package:karmashala_terminal_runtime/launch.dart';
import 'package:karmashala_terminal_runtime/instances.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_core/shell_integration.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shellSupportsIntegration', () {
    test('PowerShell and WSL are integrated, cmd.exe never', () {
      expect(shellSupportsIntegration(TerminalShell.powerShell), isTrue);
      // A WSL pane is instrumented by the payload its launch already carries;
      // `cmd.exe` has no hook between reading a command and running it, and its
      // PROMPT cannot carry a live exit code — both measured, see the doc.
      expect(shellSupportsIntegration(TerminalShell.wsl), isTrue);
      expect(shellSupportsIntegration(TerminalShell.commandPrompt), isFalse);
    });
  });

  group('ptyLaunchFor with integration off', () {
    test('the PowerShell launch is byte-identical to no integration', () {
      final off = ptyLaunchFor(TerminalProfile.powerShell);
      final explicit = ptyLaunchFor(
        TerminalProfile.powerShell,
        shellIntegration: false,
      );
      expect(off.executable, 'powershell.exe');
      expect(off.arguments, const [
        '-NoLogo',
      ], reason: 'the default must not change what today ships');
      expect(explicit.arguments, off.arguments);
    });

    test('cmd is unchanged even when integration is on', () {
      final cmd = ptyLaunchFor(
        TerminalProfile.commandPrompt,
        shellIntegration: true,
      );
      expect(cmd.executable, 'cmd.exe');
      expect(cmd.arguments, isEmpty);
    });

    test('a WSL pane with integration off is byte-identical to before', () {
      const wsl = TerminalProfile(
        id: 'wsl:Ubuntu',
        label: 'Ubuntu (WSL)',
        shell: TerminalShell.wsl,
        wslDistribution: 'Ubuntu',
      );
      final launch = ptyLaunchFor(wsl);
      expect(launch.executable, 'cmd.exe');
      expect(launch.arguments, const ['/c', 'wsl.exe -d Ubuntu']);
    });
  });

  group('ptyLaunchFor with integration on', () {
    test('appends -NoExit -Command after -NoLogo', () {
      final launch = ptyLaunchFor(
        TerminalProfile.powerShell,
        shellIntegration: true,
      );
      expect(launch.executable, 'powershell.exe');
      expect(launch.arguments.length, 4);
      expect(launch.arguments[0], '-NoLogo');
      expect(launch.arguments[1], '-NoExit');
      expect(launch.arguments[2], '-Command');
      expect(launch.arguments[3], powerShellIntegrationScript());
    });

    test('the working directory is still passed through', () {
      final launch = ptyLaunchFor(
        TerminalProfile.powerShell,
        workingDirectory: r'C:\ws',
        shellIntegration: true,
      );
      expect(launch.workingDirectory, r'C:\ws');
    });
  });

  group('powerShellIntegrationScript', () {
    final script = powerShellIntegrationScript();

    test('never suppresses or rewrites the user profile', () {
      // The whole mechanism depends on -Command running AFTER profiles
      // load, so the user's final prompt is the one we wrap. Touching any of
      // these would defeat that or alter the user's environment.
      expect(script, isNot(contains('NoProfile')));
      expect(script, isNot(contains(r'$PROFILE')));
      expect(script, isNot(contains('ExecutionPolicy')));
    });

    test('runs only in FullLanguage mode', () {
      // Under ConstrainedLanguage the wrapping cannot work; skip rather than
      // throw in the user's face.
      expect(script, contains('LanguageMode'));
      expect(script, contains('FullLanguage'));
    });

    test('is idempotent via a sentinel', () {
      // Running twice would double-wrap the prompt and emit doubled markers.
      expect(script, contains('Test-Path variable:global:__CgOsc133'));
    });

    test('captures the success bit as the prompt function first statement', () {
      // Any expression before this clobbers $?, which is the only reliable
      // did-it-fail signal PowerShell offers.
      final body = script.split('function Global:prompt {')[1];
      final firstStatement = body
          .split('\n')
          .map((l) => l.trim())
          .firstWhere((l) => l.isNotEmpty);
      expect(firstStatement, r'$__cgOk = $?');
    });

    test('restores LASTEXITCODE before invoking the user prompt', () {
      final body = script.split('function Global:prompt {')[1];
      final restore = body.indexOf(r'$global:LASTEXITCODE = $__cgLast');
      final invoke = body.indexOf('OriginalPrompt.Invoke()');
      expect(restore, greaterThan(-1));
      expect(invoke, greaterThan(-1));
      expect(
        restore,
        lessThan(invoke),
        reason: 'a user prompt that renders the last exit code must see it',
      );
    });

    test('re-falsifies the success bit for the user prompt', () {
      // A prompt that renders a red arrow on failure reads $?; our own
      // statements have already made it true by the time we call them.
      expect(script, contains("Write-Error 'failure' -ea ignore"));
    });

    test('turns strict mode off inside the prompt', () {
      // A user profile may have set -Version Latest globally, which would make
      // our own hashtable lookups fatal.
      expect(script, contains('Set-StrictMode -Off'));
    });

    test('emits no D before the first prompt', () {
      expect(script, contains('SeenPrompt'));
      final body = script.split('function Global:prompt {')[1];
      final guard = body.indexOf(r'if ($Global:__CgOsc133.SeenPrompt)');
      final emitD = body.indexOf('133;D;');
      expect(guard, greaterThan(-1));
      expect(
        guard,
        lessThan(emitD),
        reason: 'there is no previous command to have finished',
      );
    });

    test('emits all four markers', () {
      expect(script, contains(r'133;A'));
      expect(script, contains(r'133;B'));
      expect(script, contains(r'133;C'));
      expect(script, contains(r'133;D;'));
    });

    test('takes C from PSConsoleHostReadLine, not a key binding', () {
      // Binding Enter would clobber the user's own PSReadLine key handlers;
      // wrapping readline leaves every binding untouched.
      expect(script, contains('function Global:PSConsoleHostReadLine'));
      expect(script, isNot(contains('Set-PSReadLineKeyHandler')));
    });

    test('guards the readline wrapper on PSReadLine being present', () {
      expect(script, contains('PSReadLine'));
      expect(script, contains('OriginalReadLine'));
    });

    test('is wrapped so a failure can never break the shell', () {
      expect(script, contains('try {'));
      expect(script, contains('} catch {'));
    });
  });

  group('the pane factory applies the same rule to the recorder', () {
    const wsl = TerminalProfile(
      id: 'wsl:Ubuntu',
      label: 'Ubuntu (WSL)',
      shell: TerminalShell.wsl,
      wslDistribution: 'Ubuntu',
    );

    bool applies(TerminalProfile profile, {bool on = true}) =>
        shellIntegrationApplies(
          profile: profile,
          shellIntegration: on,
          agentLaunch: null,
        );

    test('a shell that cannot emit markers does not get a recorder', () {
      // The factory used to gate on the setting alone, so with integration on
      // every cmd.exe pane carried a live CommandBlockRecorder and a permanent
      // onPrivateOSC listener that no marker could reach.
      expect(applies(TerminalProfile.powerShell), isTrue);
      expect(applies(wsl), isTrue);
      expect(applies(TerminalProfile.commandPrompt), isFalse);
    });

    test('and cmd.exe still starts, byte-for-byte as before', () {
      // The other half of that fix: withholding the recorder must not withhold
      // the shell.
      final off = ptyLaunchFor(TerminalProfile.commandPrompt);
      final on = ptyLaunchFor(
        TerminalProfile.commandPrompt,
        shellIntegration: true,
      );
      expect(on.executable, off.executable);
      expect(on.arguments, off.arguments);
    });

    test('the setting still has to be on', () {
      expect(applies(TerminalProfile.powerShell, on: false), isFalse);
    });

    test('an agent pane runs no shell, so it never records', () {
      expect(
        shellIntegrationApplies(
          profile: TerminalProfile.powerShell,
          shellIntegration: true,
          agentLaunch: const AgentPaneLaunch(
            agentId: 'claude-code',
            executable: r'C:\bin\claude.exe',
          ),
        ),
        isFalse,
      );
    });
  });
}
