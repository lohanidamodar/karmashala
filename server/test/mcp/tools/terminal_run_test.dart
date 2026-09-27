import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/src/domain/session_registry.dart';
import 'package:karmashala_host/src/mcp/tools/terminal_tool_set.dart';
import 'package:karmashala_host/src/pty/fake_pty.dart';
import 'package:karmashala_host/src/terminals/server_terminals.dart';
import 'package:karmashala_launch/karmashala_launch.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// `terminal_run` in the server (slice 5b): it types the command into the
/// server's terminal and waits for **that** command on the OSC 133 markers
/// the server's own copy of the screen reads. It never invents an exit code.
void main() {
  late FakePtyLauncher launcher;
  late SessionRegistry registry;
  late ServerTerminals terminals;
  late AppDatabase database;
  late TerminalToolSet tools;

  setUp(() {
    launcher = FakePtyLauncher();
    registry = SessionRegistry(launcher: launcher, hostname: 'this-mac');
    terminals = ServerTerminals(
      registry: registry,
      environments: () => const [],
      tell: (_) {},
      hostEnvironment: const {'SHELL': '/bin/zsh'},
      installedShells: () => const ['/bin/zsh'],
      windows: false,
      settle: Duration.zero,
    );
    database = AppDatabase.memory();
    tools = TerminalToolSet(
      terminals: terminals,
      registry: registry,
      data: DataService(database),
      newPaneId: () => 'p1',
      defaultTimeout: const Duration(milliseconds: 300),
    );
  });

  tearDown(() async {
    for (final handle in launcher.handles) {
      handle.finish(0);
    }
    await terminals.dispose();
    database.close();
  });

  Future<Map<String, Object?>> run(
    String command, {
    num? timeoutSeconds,
  }) async =>
      (await tools.call('terminal_run', {
            'paneId': 'p1',
            'command': command,
            'timeoutSeconds': ?timeoutSeconds,
          }, null))!
          as Map<String, Object?>;

  FakePtyHandle openShell() {
    terminals.open(const TerminalOpen(paneId: 'p1', columns: 80, rows: 24));
    return launcher.handles.single;
  }

  void say(FakePtyHandle pty, String text) => pty.emit(utf8.encode(text));

  /// A prompt, so the screen has seen the integration's markers.
  Future<void> prompt(FakePtyHandle pty) async {
    say(pty, '\x1b]133;A\x07\$ \x1b]133;B\x07');
    await pumpEventQueue();
  }

  /// The shell runs [command]: echoes it, starts it, prints, ends it.
  void shellRuns(FakePtyHandle pty, String command, String output, int? code) {
    say(pty, '$command\r\n\x1b]133;C\x07$output');
    say(pty, code == null ? '\x1b]133;D\x07' : '\x1b]133;D;$code\x07');
    say(pty, '\x1b]133;A\x07\$ \x1b]133;B\x07');
  }

  group('a shell that reports its command boundaries', () {
    test(
      'waits for the command, and answers its output and exit code',
      () async {
        final pty = openShell();
        await prompt(pty);
        final running = run('make test');
        await pumpEventQueue();
        expect(
          utf8.decode(pty.writes.expand((b) => b).toList()),
          'make test\r',
        );
        shellRuns(pty, 'make test', 'all passed\r\n', 0);
        final result = await running;
        expect(result['finished'], isTrue);
        expect(result['exitCode'], 0);
        expect(result['exitCodeKnown'], isTrue);
        expect(result['output'], ['all passed']);
        expect(result['note'], 'Finished with exit code 0.');
        expect(result['durationMs'], isA<int>());
      },
    );

    test('a non-zero exit is reported as one, not as a success', () async {
      final pty = openShell();
      await prompt(pty);
      final running = run('false');
      await pumpEventQueue();
      shellRuns(pty, 'false', '', 1);
      final result = await running;
      expect(result['exitCode'], 1);
      expect(result['note'], 'Finished with exit code 1.');
    });

    test('the output is this command\'s, not the pane\'s scrollback', () async {
      final pty = openShell();
      await prompt(pty);
      say(pty, 'old line\r\nolder line\r\n');
      await prompt(pty);
      final running = run('echo hi');
      await pumpEventQueue();
      shellRuns(pty, 'echo hi', 'hi\r\n', 0);
      final result = await running;
      expect(result['output'], ['hi']);
    });

    test('two runs in a row keep their own exit codes', () async {
      final pty = openShell();
      await prompt(pty);
      final first = run('true');
      await pumpEventQueue();
      shellRuns(pty, 'true', '', 0);
      expect((await first)['exitCode'], 0);
      final second = run('false');
      await pumpEventQueue();
      shellRuns(pty, 'false', '', 3);
      expect((await second)['exitCode'], 3);
    });

    test('an interrupted command has no code, and says UNKNOWN', () async {
      final pty = openShell();
      await prompt(pty);
      final running = run('sleep 99');
      await pumpEventQueue();
      shellRuns(pty, 'sleep 99', '^C\r\n', null);
      final result = await running;
      expect(result['finished'], isTrue);
      expect(result['exitCode'], isNull);
      expect(result['exitCodeKnown'], isFalse);
      expect(result['note'], contains('UNKNOWN'));
    });

    test('the end of an earlier command does not satisfy a new call', () async {
      final pty = openShell();
      await prompt(pty);
      say(pty, 'server\r\n\x1b]133;C\x07listening\r\n');
      await pumpEventQueue();
      final running = run('ls');
      await pumpEventQueue();
      // The earlier command ends first; ours only after.
      say(pty, '\x1b]133;D;130\x07\x1b]133;A\x07\$ \x1b]133;B\x07');
      await pumpEventQueue();
      shellRuns(pty, 'ls', 'a b\r\n', 0);
      final result = await running;
      expect(result['exitCode'], 0);
      expect(result['output'], ['a b']);
    });

    test('still running at the timeout: partial output, no code', () async {
      final pty = openShell();
      await prompt(pty);
      final running = run('npm run dev', timeoutSeconds: 0.2);
      await pumpEventQueue();
      say(pty, 'npm run dev\r\n\x1b]133;C\x07ready on :3000\r\n');
      final result = await running;
      expect(result['finished'], isFalse);
      expect(result['exitCode'], isNull);
      expect(result['output'], ['ready on :3000']);
      expect(result['note'], contains('still running in pane p1 after 200ms'));
    });

    test('a terminal whose process dies is not waited on to the timeout, and '
        'reports the session\'s code as the session\'s', () async {
      final pty = openShell();
      await prompt(pty);
      final running = run('exit 4', timeoutSeconds: 30);
      await pumpEventQueue();
      say(pty, 'exit 4\r\n\x1b]133;C\x07');
      await pumpEventQueue();
      pty.finish(4);
      final result = await running.timeout(const Duration(seconds: 5));
      expect(result['finished'], isFalse);
      expect(result['exitCode'], 4);
      expect(result['note'], contains('SESSION\'s code'));
    });
  });

  group('a shell with no integration', () {
    test('types the command, returns at once, and is honest that the exit '
        'code is unknown', () async {
      final pty = openShell();
      final result = await run('ls').timeout(const Duration(seconds: 2));
      expect(utf8.decode(pty.writes.expand((b) => b).toList()), 'ls\r');
      expect(result['finished'], isFalse);
      expect(result['exitCodeKnown'], isFalse);
      expect(result['note'], startsWith('Typed and submitted, but NOT waited'));
    });
  });

  group('refusals', () {
    test('an agent\'s terminal is refused in words, not typed into', () async {
      terminals.open(
        const TerminalOpen(
          paneId: 'p1',
          agentLaunch: AgentPaneLaunch(
            agentId: 'claude-code',
            executable: '/bin/claude',
            sessionId: 'row1',
          ),
          columns: 80,
          rows: 24,
        ),
      );
      await expectLater(
        run('ls'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('running the claude-code CLI, not a shell'),
          ),
        ),
      );
      expect(launcher.handles.single.writes, isEmpty);
    });

    test('an ended terminal has no shell to type into', () async {
      final pty = openShell();
      pty.finish(0);
      await registry.find('karmashala_local_p1')!.ended;
      await expectLater(run('ls'), throwsA(isA<StateError>()));
    });

    test('an unknown pane and a blank command are refused', () async {
      await expectLater(run('ls'), throwsA(isA<StateError>()));
      openShell();
      await expectLater(run('  '), throwsA(isA<ArgumentError>()));
    });
  });
}
