import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/data/pty_launch.dart';
import 'package:karmashala_terminal_core/profiles.dart';

/// The command line `flutter_pty` 0.4.2 really hands to `CreateProcessW`.
///
/// Its `build_command` (`src/flutter_pty_win.c`) writes the executable and then
/// every entry of `argv`, and `flutter_pty.dart` has already put the executable
/// at `argv[0]` — so the executable is written **twice**, and the arguments are
/// concatenated with single spaces and no quoting of their own.
///
/// Asserting on this string rather than on [PtyLaunch]'s fields is the whole
/// point of this file: the fields looked correct all along, and the bug was
/// only ever visible in what the tokens mean once they reach the child.
String conPtyCommandLine(PtyLaunch launch) =>
    [launch.executable, launch.executable, ...launch.arguments].join(' ');

const _ubuntu = TerminalProfile(
  id: 'wsl:Ubuntu',
  label: 'Ubuntu (WSL)',
  shell: TerminalShell.wsl,
  wslDistribution: 'Ubuntu',
);

void main() {
  group('the command line a WSL pane really gets', () {
    // Each of these was run for real, as a command line, on Windows
    // 10.0.26200 against the `archlinux` distribution. The old form is kept
    // beside the new one because the difference is the bug.
    test('goes through cmd.exe, so wsl.exe sees its own options', () {
      final launch = ptyLaunchFor(_ubuntu, workingDirectory: r'C:\repo');

      expect(
        conPtyCommandLine(launch),
        r'cmd.exe cmd.exe /c wsl.exe -d Ubuntu --cd C:\repo',
        reason:
            'cmd.exe drops the stray leading token and re-parses; `wsl.exe '
            'wsl.exe -d …` instead made the second token the command to run '
            'inside the distro',
      );
      // The pane's process is cmd.exe now, which is also what the controller
      // asks this builder for when it decides which OSC title to refuse.
      expect(launch.executable, 'cmd.exe');
      // wsl.exe sets the child's directory with --cd; the host process must not
      // also be pointed at a path Windows may not be able to resolve.
      expect(launch.workingDirectory, isNull);
    });

    test('a working directory with a space stays one argument', () {
      final launch = ptyLaunchFor(
        _ubuntu,
        workingDirectory: r'C:\src\space dir',
      );
      expect(
        conPtyCommandLine(launch),
        r'cmd.exe cmd.exe /c wsl.exe -d Ubuntu --cd "C:\src\space dir"',
      );
    });

    test('a Linux working directory is passed through untouched', () {
      final launch = ptyLaunchFor(_ubuntu, workingDirectory: '/home/me/app');
      expect(
        conPtyCommandLine(launch),
        'cmd.exe cmd.exe /c wsl.exe -d Ubuntu --cd /home/me/app',
      );
    });

    test('no working directory means no --cd at all', () {
      expect(
        conPtyCommandLine(ptyLaunchFor(_ubuntu)),
        'cmd.exe cmd.exe /c wsl.exe -d Ubuntu',
      );
    });

    test('shell integration keeps the shape and changes the payload', () {
      // The markers come from the distribution's own prompt hooks, installed by
      // a bootstrap carried on the `--` payload this line already had a form
      // for. Nothing about `cmd.exe /c wsl.exe -d …` moves.
      final line = conPtyCommandLine(
        ptyLaunchFor(_ubuntu, shellIntegration: true),
      );
      expect(line, startsWith('cmd.exe cmd.exe /c wsl.exe -d Ubuntu -- eval '));
      // And it fits, with room to spare, in the 8191 characters `cmd.exe`
      // allows: base64 is four bytes for three, and a working directory has to
      // go on the same line.
      expect(line.length, lessThan(5000));
    });
  });

  group('the command line the other Windows panes really get', () {
    // Neither is changed here. Both are pinned because the WSL fix is a change
    // to the *shape* every Windows branch shares, and the one thing worse than
    // this bug would be quietly re-shaping the default profile with it.
    test('a cmd.exe pane needs no wrapper', () {
      // Measured: `cmd.exe cmd.exe` starts exactly one shell — one banner, one
      // prompt, one process — because cmd discards the stray token.
      expect(
        conPtyCommandLine(ptyLaunchFor(TerminalProfile.commandPrompt)),
        'cmd.exe cmd.exe',
      );
      expect(ptyLaunchFor(TerminalProfile.commandPrompt).arguments, isEmpty);
    });

    test('a PowerShell pane is still nested, knowingly', () {
      // Measured: two `powershell.exe` processes. PowerShell's first
      // positional parameter is `-Command`, so the duplicate binds to it and
      // `-NoLogo` ends up inside the command string rather than applied to the
      // outer shell. It works — the inner shell is the interactive one — and
      // fixing it is [throughCommandPrompt], not something to slip in here.
      expect(
        conPtyCommandLine(ptyLaunchFor(TerminalProfile.powerShell)),
        'powershell.exe powershell.exe -NoLogo',
      );
    });

    test('the PowerShell integration bootstrap is a plain -Command', () {
      // It was `-EncodedCommand`; see windows_powershell_launch_test.dart for
      // the command line flutter_pty now really builds for it.
      final launch = ptyLaunchFor(
        TerminalProfile.powerShell,
        shellIntegration: true,
      );
      expect(launch.executable, 'powershell.exe');
      expect(launch.arguments.take(3), ['-NoLogo', '-NoExit', '-Command']);
    });
  });

  group('throughCommandPrompt', () {
    test('quotes only what a re-parse would otherwise split', () {
      expect(throughCommandPrompt(['a.exe', 'plain', 'two words']).arguments, [
        '/c',
        'a.exe plain "two words"',
      ]);
    });

    test('carries the working directory and environment through', () {
      final launch = throughCommandPrompt(
        ['a.exe'],
        workingDirectory: r'C:\ws',
        environment: const {'K': 'v'},
      );
      expect(launch.workingDirectory, r'C:\ws');
      expect(launch.environment, {'K': 'v'});
    });
  });

  group('and the command line a WSL *agent* pane really gets', () {
    // The owner's report: resuming a WSL agent session dies as
    // `/mnt/c/…/wsl.exe: line 1: MZ: command not found` whenever WSL interop is
    // unregistered. Spawned directly, the duplicated leading token makes
    // `wsl.exe` treat the second `wsl.exe` as the command to run *inside* the
    // distro, so the login shell execs a Windows PE back out through
    // `binfmt_misc` — and reads its `MZ` header as a script when it cannot.
    ShellCommand resume() => const ShellCommand(
      executable: 'claude',
      arguments: ['--resume', 'abc123'],
      workingDirectory: '/home/me/proj',
    );

    test('a resume goes through cmd.exe, so nothing crosses back out', () {
      final launch = wrapForPty(resume(), const LaunchContext.wsl('Ubuntu'));

      expect(
        conPtyCommandLine(launch),
        startsWith(
          'cmd.exe cmd.exe /c wsl.exe -d Ubuntu --cd /home/me/proj -- eval ',
        ),
        reason:
            'cmd drops the stray token, so wsl.exe sees its own options '
            'and runs the agent in the distro with no PE round-trip',
      );
      expect(decodedPosixScript(launch), "exec 'claude' '--resume' 'abc123'");
    });

    test('the payload is one double-quoted token, and nothing else is', () {
      // The shape the whole fix rests on. `wsl.exe … --` gives the tail to the
      // distro's login shell, so what that shell reads back has to be one word
      // with the substitution live — which is what a Windows `"…"` is.
      final line = conPtyCommandLine(
        wrapForPty(resume(), const LaunchContext.wsl('Ubuntu')),
      );
      expect(
        RegExp(
          r'''-- eval "\$\(echo '[A-Za-z0-9+/=]+'\|base64 -d\)"$''',
        ).hasMatch(line),
        isTrue,
        reason: line,
      );
      // Nothing `cmd` rewrites or stops at can be left in the line.
      final payload = line.substring(line.indexOf('-- eval '));
      expect(payload, isNot(contains('%')));
      expect(payload, isNot(contains('\n')));
    });

    test('an ordinary prompt survives as one argument', () {
      final launch = wrapForPty(
        const ShellCommand(
          executable: 'claude',
          arguments: ['fix the failing test'],
          workingDirectory: '/home/me/proj',
        ),
        const LaunchContext.wsl('Ubuntu'),
      );

      expect(conPtyCommandLine(launch), startsWith('cmd.exe cmd.exe /c '));
      expect(
        decodedPosixScript(launch),
        "exec 'claude' 'fix the failing test'",
      );
    });

    // Every one of these was measured against a real `archlinux` pane before
    // the fix, and every one of them arrived wrong. The first six are the
    // characters a POSIX shell acts on; the last three are what `cmd.exe` acts
    // on. `live_wsl_prompt_test.dart` asserts the same list against a real
    // ConPTY — this file is the part that runs on every gate.
    const hostile = <String, String>{
      'a double quote': 'he said "hello" to me',
      'an unbalanced double quote': 'he said "hello',
      'a single quote': "it's a trap",
      'a backtick': 'run `id -u` and report',
      'a command substitution': r'run $(id -u) and report',
      'a bare variable': r'my $HOME is here',
      'a semicolon': 'a; rm -rf ~; b',
      'a percent sign': 'about 50%USERNAME% done',
      'a newline': 'line one\nline two',
    };

    for (final entry in hostile.entries) {
      test('a prompt containing ${entry.key} reaches the agent unchanged', () {
        final launch = wrapForPty(
          ShellCommand(executable: 'claude', arguments: [entry.value]),
          const LaunchContext.wsl('Ubuntu'),
        );

        // Decoded, it is a single POSIX-quoted argument: nothing to expand,
        // nothing to split, nothing to run.
        expect(
          decodedPosixScript(launch),
          "exec 'claude' ${quotePosixShellArgument(entry.value)}",
        );
        // And on the way there, none of it is on the command line at all.
        final line = conPtyCommandLine(launch);
        expect(line, isNot(contains(entry.value)));
        expect(line, isNot(contains('\n')));
        expect(line.substring(line.indexOf('-- eval ')), isNot(contains('%')));
      });
    }

    test('and the environment still crosses with WSLENV naming it', () {
      final launch = wrapForPty(
        const ShellCommand(
          executable: 'claude',
          arguments: ['go'],
          workingDirectory: '/home/me/proj',
          environment: {'KARMASHALA_SESSION': 's1'},
        ),
        const LaunchContext.wsl('Ubuntu'),
      );

      expect(launch.environment['KARMASHALA_SESSION'], 's1');
      expect(launch.environment['WSLENV'], 'KARMASHALA_SESSION/u');
    });
  });

  group('quotePosixShellArgument', () {
    test('leaves ordinary text alone inside single quotes', () {
      expect(quotePosixShellArgument('plain'), "'plain'");
      expect(quotePosixShellArgument('two words'), "'two words'");
      expect(quotePosixShellArgument(''), "''");
    });

    test('neutralises everything a POSIX shell would act on', () {
      for (final value in [
        r'$HOME',
        r'$(id -u)',
        '`id -u`',
        'a; b',
        'a && b',
        'a | b',
        'a > b',
        '*.dart',
        '~',
        'line\nline',
        r'back\slash',
        '50%',
      ]) {
        expect(quotePosixShellArgument(value), "'$value'");
      }
    });

    test('splices a single quote out and back in', () {
      // The one character single quotes cannot contain. `'\''` closes, escapes
      // the quote outside, and reopens.
      expect(quotePosixShellArgument("it's"), r"'it'\''s'");
      expect(quotePosixShellArgument("'"), r"''\'''");
    });
  });

  group('encodedPosixShellCommand', () {
    test('is two tokens, and only the second needs quoting', () {
      final tokens = encodedPosixShellCommand(['claude', 'go']);
      expect(tokens.first, 'eval');
      expect(quoteWindowsCommandArgument(tokens.first), 'eval');
      expect(
        quoteWindowsCommandArgument(tokens.last),
        '"${tokens.last}"',
        reason:
            'the second token has to arrive double-quoted or the shell splits '
            'the decoded script on IFS',
      );
    });

    test('carries anything at all, base64 and nothing else', () {
      final tokens = encodedPosixShellCommand([
        'claude',
        'a "b" `c` \$(d) 50% e\nf',
      ]);
      expect(
        RegExp(
          r'''^\$\(echo '[A-Za-z0-9+/=]+'\|base64 -d\)$''',
        ).hasMatch(tokens.last),
        isTrue,
        reason: tokens.last,
      );
    });
  });

  group('the argv an external terminal is handed', () {
    // `wsl.exe … --` is a shell hand-off wherever it is spelled, so this path
    // carries the same encoded payload — `_startInExternalTerminal` puts a
    // prompt through it.
    test('crosses WSL through the same encoded payload', () {
      final argv = wrapForExternalTerminal(
        const ShellCommand(
          executable: 'claude',
          arguments: ['say "hi" and run `id`'],
          workingDirectory: '/home/me/proj',
        ),
        const LaunchContext.wsl('Ubuntu'),
      );

      expect(argv.take(6), [
        'wsl.exe',
        '-d',
        'Ubuntu',
        '--cd',
        '/home/me/proj',
        '--',
      ]);
      expect(argv[6], 'eval');
      expect(
        utf8.decode(
          base64Decode(
            RegExp(r"'([A-Za-z0-9+/=]+)'").firstMatch(argv[7])!.group(1)!,
          ),
        ),
        "exec 'claude' 'say \"hi\" and run `id`'",
      );
    });

    test('and leaves a non-WSL command exactly as it was', () {
      const command = ShellCommand(
        executable: 'claude',
        arguments: ['say "hi"'],
      );
      expect(
        wrapForExternalTerminal(command, const LaunchContext.windowsNative()),
        ['claude', 'say "hi"'],
      );
      expect(wrapForExternalTerminal(command, const LaunchContext.posix()), [
        'claude',
        'say "hi"',
      ]);
    });
  });
}

/// The POSIX script a WSL launch really hands the distribution's login shell.
///
/// Asserting on this rather than on the base64 is the point: the blob is an
/// encoding detail, and what has to be right is the command on the other side
/// of it.
String decodedPosixScript(PtyLaunch launch) {
  final match = RegExp(
    r"eval \x22\$\(echo '([A-Za-z0-9+/=]+)'\|base64 -d\)\x22",
  ).firstMatch(launch.arguments.last);
  expect(match, isNotNull, reason: 'not an encoded WSL launch: $launch');
  return utf8.decode(base64Decode(match!.group(1)!));
}
