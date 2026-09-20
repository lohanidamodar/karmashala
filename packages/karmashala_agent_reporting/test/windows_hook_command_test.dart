import 'dart:convert';
import 'dart:io';

import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;

import 'support/temp_directory.dart';

/// **The Windows hook command must mean the same thing to every shell.**
///
/// Claude Code runs a hook through Git Bash when it is installed and through
/// PowerShell when it is not. The old `cmd.exe /c "%USERPROFILE%\…"` was only
/// right under cmd: Git Bash's MSYS path conversion turns `/c` into `C:/`, cmd
/// started interactively, and the hook's JSON payload on stdin ran as command
/// lines. Every `=>` in a payload left an empty file named after the next word
/// in the agent's working directory, and an `&` would have run what followed.
void main() {
  const installer = AgentHookInstaller();
  const endpoint = AgentHookEndpoint(port: 4242, token: 'tok');
  final claude = AgentRegistry.builtIn.byId('claudeCode')!;

  String commandFor(String event) => installer.hookCommand(
    descriptor: claude,
    event: event,
    endpoint: endpoint,
    environment: EnvironmentKind.windowsNative,
  )!;

  test('is bare words and base64: nothing any shell rewrites', () {
    final command = commandFor('PostToolUse');
    expect(
      command,
      matches(RegExp(r'^powershell\.exe( -?[A-Za-z]+)+ [A-Za-z0-9+/]+=*$')),
    );
    // Each of these is something one of the three shells would rewrite.
    for (final hazard in ['"', "'", '%', r'$', ' /', '&', '>', '<', '|']) {
      expect(command, isNot(contains(hazard)), reason: hazard);
    }
    expect(
      decodeWindowsHookScript(command),
      '& "\$env:USERPROFILE\\.claude\\$agentHookMarker.cmd" PostToolUse; '
      'exit \$LASTEXITCODE',
    );
  });

  test('decoding refuses anything that is not one of these commands', () {
    expect(decodeWindowsHookScript('cmd.exe /c "x.cmd" Stop'), isNull);
    expect(
      decodeWindowsHookScript(
        'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass '
        '-EncodedCommand not*base64',
      ),
      isNull,
    );
    expect(
      decodeWindowsHookScript(windowsHookCommand('anything at all')),
      'anything at all',
    );
  });

  group('in a config', () {
    late Directory home;
    setUp(() => home = Directory.systemTemp.createTempSync('karmashala_wh_'));
    tearDown(() => removeTempDirectory(home));

    File config() => File(p.join(home.path, 'settings.json'));

    List<String> stopCommands() {
      final json = jsonDecode(config().readAsStringSync()) as Map;
      return [
        for (final group in (json['hooks'] as Map)['Stop'] as List)
          for (final hook in (group as Map)['hooks'] as List)
            (hook as Map)['command'] as String,
      ];
    }

    Map<String, Object?> entry(String command) => {
      'hooks': [
        {'type': 'command', 'command': command},
      ],
    };

    test(
      'upgrading replaces the old cmd.exe entry rather than adding one',
      () async {
        config().writeAsStringSync(
          jsonEncode({
            'hooks': {
              'Stop': [
                entry(
                  'cmd.exe /c "%USERPROFILE%\\.claude\\$agentHookMarker.cmd" Stop',
                ),
              ],
            },
          }),
        );

        await installer.install(
          descriptor: claude,
          storeHome: home.path,
          endpoint: endpoint,
          environment: EnvironmentKind.windowsNative,
        );

        expect(stopCommands(), [commandFor('Stop')]);
      },
    );

    test(
      'a second install finds its own encoded entry and adds nothing',
      () async {
        for (var i = 0; i < 2; i++) {
          await installer.install(
            descriptor: claude,
            storeHome: home.path,
            endpoint: endpoint,
            environment: EnvironmentKind.windowsNative,
          );
        }
        expect(stopCommands(), [commandFor('Stop')]);
      },
    );

    test('someone else\'s encoded PowerShell hook is left alone', () async {
      // The shape another tool on this machine really uses.
      final theirs = windowsHookCommand(
        r"& 'C:\Users\me\.orca\agent-hooks\claude-hook.cmd'; exit $LASTEXITCODE",
      );
      config().writeAsStringSync(
        jsonEncode({
          'hooks': {
            'Stop': [entry(theirs)],
          },
        }),
      );

      await installer.install(
        descriptor: claude,
        storeHome: home.path,
        endpoint: endpoint,
        environment: EnvironmentKind.windowsNative,
      );

      expect(stopCommands(), [theirs, commandFor('Stop')]);
    });
  });

  /// The real thing: the generated command, run the way Claude Code runs it
  /// when Git Bash is installed, with a payload built to leak.
  group('run under Git Bash', () {
    const bash = r'C:\Program Files\Git\bin\bash.exe';
    final skip = !Platform.isWindows
        ? 'Windows only'
        : !File(bash).existsSync()
        ? 'Git Bash is not installed at $bash'
        : false;

    late Directory profile;
    late Directory cwd;
    setUp(() {
      profile = Directory.systemTemp.createTempSync('karmashala_wh_profile_');
      cwd = Directory.systemTemp.createTempSync('karmashala_wh_cwd_');
      // Stands in for the generated script: records its argument and stdin.
      Directory(p.join(profile.path, '.claude')).createSync();
      File(
        p.join(profile.path, '.claude', '$agentHookMarker.cmd'),
      ).writeAsStringSync(
        '@echo off\r\n'
        '> "%~dp0got.txt" echo arg=%~1\r\n'
        'findstr "^" >> "%~dp0got.txt"\r\n',
      );
    });
    tearDown(() {
      removeTempDirectory(profile);
      removeTempDirectory(cwd);
    });

    test(
      'delivers the payload and the event, and runs none of it',
      () async {
        // The `\"` is what real payloads carry and what made the old command
        // leak: it flips cmd's quote state, leaving `=>` and `&` outside
        // quotes. Under the old spelling this exact line left `leaked_file`
        // and `b` in the working directory and never reached the script.
        const payload =
            r'{"a":"x \" => leaked_file","b":"y \" & echo pwned > injected"}';
        final process = await Process.start(
          bash,
          ['-c', commandFor('PostToolUse')],
          workingDirectory: cwd.path,
          environment: {'USERPROFILE': profile.path},
        );
        process.stdin.write('$payload\n');
        await process.stdin.close();
        final stdout = await process.stdout.transform(utf8.decoder).join();
        final exitCode = await process.exitCode;

        expect(exitCode, 0, reason: stdout);
        final got = File(
          p.join(profile.path, '.claude', 'got.txt'),
        ).readAsStringSync();
        expect(got, contains('arg=PostToolUse'));
        expect(got, contains(payload));
        expect(cwd.listSync(), isEmpty);
      },
      skip: skip,
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });
}
