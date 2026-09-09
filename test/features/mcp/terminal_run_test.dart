import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/mcp/terminal_tools.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/domain/agent_pane_launch.dart';
import 'package:karmashala/src/features/terminal/domain/pane_liveness.dart';
import 'package:xterm2/xterm.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// `terminal_run` waiting for the command it typed.
///
/// The point of the whole feature: an agent's own shell tool runs a process,
/// waits, and hands back output and an exit code in one round trip. Until this,
/// an in-app pane could only be typed into and then polled — which is why
/// agents spawned consoles of their own instead of working in the user's
/// terminal. Every test here is about the tool answering the two questions
/// polling could not: *did this command finish*, and *what did **it** print*.
///
/// The tools are called directly rather than over the HTTP endpoint (which
/// `terminal_control_tools_test.dart` covers) because these tests have to drive
/// the shell's replies *while* a call is in flight.
void main() {
  late AppDatabase db;
  late ProviderContainer container;

  void open({required bool shellIntegration}) {
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(
          database: db,
          shellIntegration: shellIntegration,
        ),
        clockProvider.overrideWithValue(FixedClock(testTime)),
      ],
    );
  }

  tearDown(() {
    container.dispose();
    db.close();
  });

  TerminalControlTools tools() => TerminalControlTools(container);

  TerminalSessionsController controller() =>
      container.read(terminalSessionsControllerProvider.notifier);

  /// Opens a pane through the tool an agent would use, and puts a shell behind
  /// it.
  Future<({String paneId, _FakeShell shell})> shellPane() async {
    final opened =
        (await tools().call('terminal_open', const {}))!
            as Map<String, Object?>;
    final paneId = opened['paneId']! as String;
    return (
      paneId: paneId,
      shell: _FakeShell(controller().instanceFor(paneId)!.terminal),
    );
  }

  Future<Map<String, Object?>> run(
    String paneId,
    String command, {
    num? timeoutSeconds,
  }) async =>
      (await tools().call('terminal_run', <String, dynamic>{
            'paneId': paneId,
            'command': command,
            'timeoutSeconds': ?timeoutSeconds,
          }))!
          as Map<String, Object?>;

  group('a shell that reports its command boundaries', () {
    setUp(() => open(shellIntegration: true));

    test(
      'a command that exits 0 comes back with its output and code',
      () async {
        final pane = await shellPane();
        pane.shell.output = ['built 42 targets', 'took 3s'];

        final result = await run(pane.paneId, 'make');

        expect(pane.shell.ran, ['make']);
        expect(result['finished'], isTrue);
        expect(result['exitCode'], 0);
        expect(result['exitCodeKnown'], isTrue);
        expect(result['output'], ['built 42 targets', 'took 3s']);
      },
    );

    test('a non-zero exit is reported as one, not as a success', () async {
      final pane = await shellPane();
      pane.shell
        ..output = ['1 test failed']
        ..exitCode = 7;

      final result = await run(pane.paneId, 'flutter test');

      expect(result['finished'], isTrue);
      expect(result['exitCode'], 7);
      expect(result['exitCodeKnown'], isTrue);
      expect(result['output'], ['1 test failed']);
    });

    test('the output is this command\'s, not the pane\'s scrollback', () async {
      final pane = await shellPane();
      pane.shell.output = ['one'];
      await run(pane.paneId, 'echo one');
      pane.shell.output = ['two'];

      final second = await run(pane.paneId, 'echo two');

      expect(second['output'], ['two']);
      // The whole difference between a usable tool and one that hands back a
      // screen: neither the earlier command's output nor either echoed prompt
      // line belongs to this command.
      final text = (second['output']! as List<Object?>).join('\n');
      expect(text, isNot(contains('one')));
      expect(text, isNot(contains('echo')));
    });

    test('two runs in a row keep their own exit codes', () async {
      final pane = await shellPane();
      pane.shell
        ..output = ['ok']
        ..exitCode = 0;
      final first = await run(pane.paneId, 'true');
      pane.shell
        ..output = ['nope']
        ..exitCode = 1;

      final second = await run(pane.paneId, 'false');

      expect(first['exitCode'], 0);
      expect(second['exitCode'], 1);
      expect(pane.shell.ran, ['true', 'false']);
    });

    test(
      'a command still running at the timeout is labelled unfinished',
      () async {
        final pane = await shellPane();
        pane.shell
          ..output = ['listening on 3000']
          ..finishes = false;

        final result = await run(
          pane.paneId,
          'npm run dev',
          timeoutSeconds: 0.2,
        );

        expect(result['finished'], isFalse);
        expect(result['exitCode'], isNull);
        expect(result['exitCodeKnown'], isFalse);
        // Partial output, and said to be partial — never truncated silently into
        // something that reads like a result.
        expect(result['output'], ['listening on 3000']);
        expect(result['note'], contains('still running'));
        expect(
          result['note'],
          contains(pane.paneId),
          reason: 'the caller needs the pane id to keep watching it',
        );
      },
    );

    test('the end of an earlier command does not satisfy a new call', () async {
      // A pane can already be mid-command when an agent calls: the `D` marker
      // that arrives next belongs to what was *already* running, and reporting
      // it would hand back someone else's exit code as this command's.
      final pane = await shellPane();
      pane.shell
        ..output = ['serving']
        ..finishes = false;
      controller()
          .instanceFor(pane.paneId)!
          .terminal
          .textInput('npm run dev\r');
      expect(pane.shell.running, isTrue);

      final call = run(pane.paneId, 'ls', timeoutSeconds: 0.3);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // The dev server exits *after* our command was typed. Its exit code is
      // not ours.
      pane.shell.exitCode = 130;
      pane.shell.finish();
      final result = await call;

      expect(result['finished'], isFalse);
      expect(result['exitCode'], isNull);
    });

    test('a pane whose process dies is not waited on to the timeout', () async {
      final pane = await shellPane();
      pane.shell.finishes = false;
      final instance =
          controller().instanceFor(pane.paneId)! as FakeTerminalInstance;

      final call = run(pane.paneId, 'exit', timeoutSeconds: 30);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // Dead, and nothing ever said with what — a tmux pane, and every pane
      // before the session host existed.
      instance.livenessNotifier.value = PaneLiveness.exited;
      final result = await call.timeout(const Duration(seconds: 5));

      expect(result['finished'], isFalse);
      expect(result['exitCode'], isNull);
      expect(result['exitCodeKnown'], isFalse);
      expect(result['note'], contains('exited'));
      expect(result['note'], contains('UNKNOWN'));
    });

    test('a pane that DOES know what it died with reports that code, and says '
        'whose it is', () async {
      // A host-backed session carries the host's own exit code, so the tool
      // has one to report even though no `D` marker ever arrived. The note and
      // `exitCodeKnown` move together: a code beside a sentence denying one
      // would be worse than either alone.
      final pane = await shellPane();
      pane.shell.finishes = false;
      final instance =
          controller().instanceFor(pane.paneId)! as FakeTerminalInstance;

      final call = run(pane.paneId, 'make', timeoutSeconds: 30);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      instance.exitWith(7);
      final result = await call.timeout(const Duration(seconds: 5));

      expect(result['finished'], isFalse, reason: 'the pane ended, not the command');
      expect(result['exitCode'], 7);
      expect(result['exitCodeKnown'], isTrue);
      expect(result['note'], contains('code 7'));
      expect(result['note'], contains("SESSION's code"));
      expect(result['note'], isNot(contains('nothing reported an exit code')));
    });

    test('a command that timed out still has no code, whatever the pane holds',
        () async {
      // The pane is alive; there is nothing to take a code from, and the one
      // the pane happens to be carrying is not this command's.
      final pane = await shellPane();
      pane.shell.finishes = false;

      final result = await run(pane.paneId, 'vim', timeoutSeconds: 0.05);

      expect(result['exitCode'], isNull);
      expect(result['exitCodeKnown'], isFalse);
      expect(result['note'], contains('still running'));
    });
  });

  group('a shell with no integration', () {
    setUp(() => open(shellIntegration: false));

    test('is honest that the exit code is unknown, and why', () async {
      final pane = await shellPane();

      final result = await run(pane.paneId, 'dir');

      expect(result['finished'], isFalse);
      expect(result['exitCode'], isNull);
      expect(result['exitCodeKnown'], isFalse);
      // Not a fake zero, and not silence either: a caller that cannot tell
      // "finished, exit 0" from "we cannot tell" makes wrong decisions.
      expect(result['note'], contains('UNKNOWN'));
      expect(result['note'], contains('shell integration'));
      expect(result['note'], contains('terminal_output'));
    });

    test('still types the command, and returns promptly', () async {
      final pane = await shellPane();
      final started = DateTime.now();

      await run(pane.paneId, 'dir', timeoutSeconds: 30);

      expect(pane.shell.ran, ['dir']);
      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(seconds: 5)),
        reason: 'a pane that cannot report an end must not be waited on',
      );
    });
  });

  group('a pane that is not a shell', () {
    setUp(() => open(shellIntegration: true));

    test('an agent pane is refused in words, not typed into', () async {
      final opened = controller().openAgentTab(
        const AgentPaneLaunch(agentId: 'claude', executable: 'claude'),
      );
      final typed = <String>[];
      controller().instanceFor(opened.paneId)!.terminal.onOutput = typed.add;

      await expectLater(
        tools().call('terminal_run', <String, dynamic>{
          'paneId': opened.paneId,
          'command': '/exit',
        }),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('claude'), contains('session_send')),
          ),
        ),
      );
      expect(
        typed,
        isEmpty,
        reason: 'nothing may land in a live agent session',
      );
    });
  });
}

/// A shell that speaks OSC 133 the way the injected PowerShell script does.
///
/// The order is the one captured in
/// `test/features/terminal/fixtures/powershell_osc133_session.txt`: the command
/// is echoed after `B`, `C` lands on the line below it, and `D` arrives with
/// the *next* prompt rather than the moment the command ends.
class _FakeShell {
  _FakeShell(this.terminal) {
    terminal.onOutput = _input;
    _prompt();
  }

  final Terminal terminal;
  final _typed = StringBuffer();

  /// What the next command prints, and what it exits with.
  List<String> output = const [];
  int exitCode = 0;

  /// When false the command never ends — no `D`, no next prompt. A dev server,
  /// a REPL, `vim`.
  bool finishes = true;

  /// The commands this shell was actually asked to run.
  final ran = <String>[];

  /// Whether a command is running, i.e. whether typing reaches a program's
  /// stdin rather than the prompt.
  bool running = false;

  void _prompt() => terminal.write('\x1b]133;A\x07PS C:\\ws> \x1b]133;B\x07');

  void _input(String data) {
    for (final rune in data.split('')) {
      if (rune == '\r') {
        _submit();
      } else {
        _typed.write(rune);
        terminal.write(rune);
      }
    }
  }

  void _submit() {
    final command = _typed.toString();
    _typed.clear();
    if (running) {
      // Typing at a busy shell reaches the running program's stdin; it starts
      // no command, and no marker is emitted for it.
      terminal.write('$command\r\n');
      return;
    }
    ran.add(command);
    running = true;
    terminal.write('\r\n\x1b]133;C\x07');
    for (final line in output) {
      terminal.write('$line\r\n');
    }
    if (finishes) finish();
  }

  /// Ends the running command, the way the next prompt does.
  void finish() {
    running = false;
    terminal.write(
      '\x1b]133;D;$exitCode\x07\x1b]133;A\x07PS C:\\ws> \x1b]133;B\x07',
    );
  }
}
