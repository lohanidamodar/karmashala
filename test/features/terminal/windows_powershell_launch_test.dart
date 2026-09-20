import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/apps/installed_applications_service.dart';
import 'package:karmashala_terminal_runtime/launch.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_core/shell_integration.dart';

import '../../support/fake_command_runner.dart';
import '../../support/windows_command_line.dart';

/// What the vendored `flutter_pty` hands `CreateProcessW` for [start]: the
/// executable, then `argv[0]` (the executable again unless suppressed), then
/// every argument, joined by single spaces and quoted by nobody.
String flutterPtyCommandLine(PtyLaunch launch) {
  final start = flutterPtyStartFor(launch, hostIsWindows: true);
  return [
    launch.executable,
    start.repeatExecutable ? launch.executable : '',
    ...start.arguments,
  ].join(' ');
}

/// Every byte `flutter_pty` would put on the line is a `char` cast to `WCHAR`,
/// so anything past ASCII arrives as garbage. The launch must not need any.
bool _isPrintableAscii(String s) =>
    s.codeUnits.every((u) => u >= 0x20 && u <= 0x7E);

const _tricky = <String>[
  'plain',
  'two words',
  'double  space',
  'say "hi" to a b',
  "it's",
  'don\u2019t',
  '\u2018smart\u2019 quotes',
  r'a & b | c > d',
  r'%PATH% and %USERPROFILE%',
  r'$env:USERPROFILE `n $(whoami)',
  'caf\u00e9',
  '\u0928\u092e\u0938\u094d\u0924\u0947',
  'emoji \u{1F600}',
  r'C:\dir with space\',
  r'C:\trailing\\',
  r'back\"slash',
  r'\\server\share\',
  'line one\nline two',
  'tab\there',
  '',
  '-c',
  'check_for_update_on_startup=false',
];

void main() {
  group('a Windows agent launch carries no encoded command', () {
    const launch = AgentPaneLaunch(
      agentId: 'codex',
      executable: r'C:\Users\me\AppData\Roaming\npm\codex.cmd',
      arguments: ['resume', 'abc'],
      workingDirectory: r'C:\repo',
    );

    test('argv is -NoLogo -NoProfile -Command <readable script>', () {
      final pty = agentPtyLaunchFor(launch);
      expect(pty.executable, 'powershell.exe');
      expect(pty.arguments, [
        '-NoLogo',
        '-NoProfile',
        '-Command',
        r"& 'C:\Users\me\AppData\Roaming\npm\codex.cmd' 'resume' 'abc'",
      ]);
      expect(pty.exactArgv, isTrue);
      for (final argument in pty.arguments) {
        expect(argument.toLowerCase(), isNot(contains('encodedcommand')));
        expect(argument.toLowerCase(), isNot(contains('executionpolicy')));
        expect(argument.toLowerCase(), isNot(contains('windowstyle')));
      }
    });

    test('flutter_pty starts ONE powershell, not a nested pair', () {
      // Before: `powershell.exe powershell.exe -NoLogo -NoProfile
      // -EncodedCommand …` — the duplicated name bound to `-Command`, so a
      // profile-loading PowerShell started a second, encoded one.
      final argv = commandLineToArgv(
        flutterPtyCommandLine(agentPtyLaunchFor(launch)),
      );
      expect(argv, [
        'powershell.exe',
        '-NoLogo',
        '-NoProfile',
        '-Command',
        r"& 'C:\Users\me\AppData\Roaming\npm\codex.cmd' 'resume' 'abc'",
      ]);
    });

    test('a launch that is not exact keeps the old flutter_pty shape', () {
      final wsl = ptyLaunchFor(
        const TerminalProfile(
          id: 'wsl:Ubuntu',
          label: 'Ubuntu (WSL)',
          shell: TerminalShell.wsl,
          wslDistribution: 'Ubuntu',
        ),
      );
      final start = flutterPtyStartFor(wsl, hostIsWindows: true);
      expect(start.repeatExecutable, isTrue);
      expect(start.arguments, wsl.arguments);
    });

    test('off Windows, flutter_pty is handed the launch untouched', () {
      final pty = agentPtyLaunchFor(launch);
      final start = flutterPtyStartFor(pty, hostIsWindows: false);
      expect(start.repeatExecutable, isTrue);
      expect(start.arguments, pty.arguments);
    });
  });

  group('tricky arguments reach the agent exactly', () {
    for (final value in _tricky) {
      test('${value.replaceAll('\n', r'\n').replaceAll('\t', r'\t')} '
          '(through flutter_pty, then PowerShell)', () {
        final launch = AgentPaneLaunch(
          agentId: 'claudeCode',
          executable: r'C:\Program Files\claude\claude.exe',
          arguments: ['--flag', value, 'tail'],
        );
        final pty = agentPtyLaunchFor(launch);
        final line = flutterPtyCommandLine(pty);
        expect(
          _isPrintableAscii(line),
          isTrue,
          reason: 'flutter_pty casts each byte to a WCHAR: $line',
        );
        final argv = commandLineToArgv(line);
        expect(argv.sublist(0, 4), [
          'powershell.exe',
          '-NoLogo',
          '-NoProfile',
          '-Command',
        ]);
        expect(argv, hasLength(5), reason: 'the script is one argument');
        expect(evaluatePowerShellInvocation(argv[4]), [
          r'C:\Program Files\claude\claude.exe',
          '--flag',
          value,
          'tail',
        ]);
      });
    }

    test('the whole list at once, in one launch', () {
      final launch = AgentPaneLaunch(
        agentId: 'claudeCode',
        executable: 'claude',
        arguments: _tricky,
      );
      final argv = commandLineToArgv(
        flutterPtyCommandLine(agentPtyLaunchFor(launch)),
      );
      expect(evaluatePowerShellInvocation(argv.last), ['claude', ..._tricky]);
    });
  });

  group('powerShellLiteral', () {
    test('plain text is a single-quoted literal and nothing else', () {
      expect(powerShellLiteral('say hello'), "'say hello'");
      expect(powerShellLiteral("it's"), "'it''s'");
      expect(powerShellLiteral(''), "''");
    });

    test('non-ASCII is spelled as character codes, never raw', () {
      expect(
        powerShellLiteral('caf\u00e9!'),
        "('caf'+[string]::new([char[]](233))+'!')",
      );
      expect(powerShellLiteral('\u2019'), '[string]::new([char[]](8217))');
    });
  });

  group('the shell-integrated PowerShell pane', () {
    test('is -NoLogo -NoExit -Command <script>, one process', () {
      final launch = ptyLaunchFor(
        TerminalProfile.powerShell,
        shellIntegration: true,
      );
      expect(launch.executable, 'powershell.exe');
      expect(launch.arguments, [
        '-NoLogo',
        '-NoExit',
        '-Command',
        powerShellIntegrationScript(),
      ]);
      expect(launch.exactArgv, isTrue);
      final argv = commandLineToArgv(flutterPtyCommandLine(launch));
      expect(argv, [
        'powershell.exe',
        '-NoLogo',
        '-NoExit',
        '-Command',
        powerShellIntegrationScript(),
      ]);
    });

    test('its script survives a command line: ASCII, no NUL', () {
      final script = powerShellIntegrationScript();
      expect(
        script.codeUnits.every((u) => u == 0x0A || (u >= 0x20 && u <= 0x7E)),
        isTrue,
      );
    });

    test('without integration it is left exactly as it shipped', () {
      final launch = ptyLaunchFor(TerminalProfile.powerShell);
      expect(launch.arguments, ['-NoLogo']);
      expect(launch.exactArgv, isFalse);
    });
  });

  group('the Start Menu pass', () {
    test('is a readable -NoProfile -Command, no policy override', () async {
      final runner = FakeCommandRunner();
      await InstalledApplicationsService(runner, windows: true).all();
      final request = runner.requests.single;
      expect(request.executable, 'powershell.exe');
      expect(request.arguments, [
        '-NoProfile',
        '-Command',
        InstalledApplicationsService.startMenuScript,
      ]);
    });
  });

  group('source guard', () {
    test('no app or package source launches an encoded or policy-bypassed '
        'PowerShell', () {
      final offenders = <String>[];
      for (final root in ['lib', 'packages']) {
        for (final entity in Directory(root).listSync(recursive: true)) {
          if (entity is! File || !entity.path.endsWith('.dart')) continue;
          final path = entity.path.replaceAll(r'\', '/');
          if (!path.startsWith('lib/') && !path.contains('/lib/')) continue;
          final text = entity.readAsStringSync();
          for (final needle in [
            "'-EncodedCommand'",
            "'-ExecutionPolicy'",
            "'-enc'",
            "'-WindowStyle'",
          ]) {
            if (text.contains(needle)) offenders.add('$path: $needle');
          }
        }
      }
      expect(offenders, isEmpty);
    });
  });
}
