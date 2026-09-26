import 'package:agent_cli/process.dart';
import 'package:karmashala_host/src/agents/forwarded_runs.dart';
import 'package:karmashala_host/src/protocol/messages.dart';
import 'package:test/test.dart';

/// **Commands the server runs through the app** (slice 2a): the one
/// connection that offered runs them; each call is answered by id, by its
/// owner; an app that hangs up or is replaced fails what it held; and a
/// command crosses as JSON without losing a field.
void main() {
  const request = CommandRequest(executable: 'uname', arguments: ['-a']);

  Matcher commandFails(String words) => throwsA(
    isA<CommandException>().having(
      (e) => e.message,
      'message',
      contains(words),
    ),
  );

  group('ForwardedRuns', () {
    late ForwardedRuns runs;
    late List<RunCallMessage> sentToA;
    late List<RunCallMessage> sentToB;
    final appA = Object();
    final appB = Object();

    void adoptA() => runs.adopt(appA, (m) => sentToA.add(m as RunCallMessage));
    void adoptB() => runs.adopt(appB, (m) => sentToB.add(m as RunCallMessage));

    setUp(() {
      runs = ForwardedRuns();
      sentToA = [];
      sentToB = [];
    });

    test('with no app every call fails, in words', () async {
      expect(runs.connected, isFalse);
      await expectLater(
        runs.run('ssh:h1', request),
        commandFails(kRunsAppNotRunning),
      );
      await expectLater(
        ForwardedCommandRunner('ssh:h1', runs).run(request),
        commandFails(kRunsAppNotRunning),
      );
    });

    test('the adopter is sent the call and its answer is the result', () async {
      adoptA();
      expect(runs.connected, isTrue);
      final running = ForwardedCommandRunner('ssh:h1', runs).run(request);
      final call = sentToA.single;
      expect(call.environmentId, 'ssh:h1');
      expect(commandRequestFromJson(call.command).executable, 'uname');

      runs.answer(
        appA,
        RunResultMessage.ran(
          call.callId,
          exitCode: 3,
          stdout: 'Linux box',
          stderr: 'warn',
        ),
      );
      final result = await running;
      expect(result.exitCode, 3);
      expect(result.stdout, 'Linux box');
      expect(result.stderr, 'warn');
    });

    test('each call is answered by its own id, in any order', () async {
      adoptA();
      final first = runs.run('ssh:h1', request);
      final second = runs.run('ssh:h1', request);
      final [a, b] = sentToA;
      expect(a.callId, isNot(b.callId));
      runs.answer(
        appA,
        RunResultMessage.ran(b.callId, exitCode: 0, stdout: 'two', stderr: ''),
      );
      runs.answer(
        appA,
        RunResultMessage.ran(a.callId, exitCode: 0, stdout: 'one', stderr: ''),
      );
      expect((await first).stdout, 'one');
      expect((await second).stdout, 'two');
    });

    test('a call the app could not run fails with its reason', () async {
      adoptA();
      final running = runs.run('ssh:h1', request);
      runs.answer(
        appA,
        RunResultMessage.failed(sentToA.single.callId, 'host key changed'),
      );
      await expectLater(running, commandFails('host key changed'));
    });

    test('an answer from anyone but the owner, or for no call, is '
        'ignored', () async {
      adoptA();
      final running = runs.run('ssh:h1', request);
      final id = sentToA.single.callId;
      runs.answer(
        appB,
        RunResultMessage.ran(id, exitCode: 9, stdout: 'forged', stderr: ''),
      );
      runs.answer(
        appA,
        RunResultMessage.ran(id + 100, exitCode: 9, stdout: '', stderr: ''),
      );
      runs.answer(
        appA,
        RunResultMessage.ran(id, exitCode: 0, stdout: 'real', stderr: ''),
      );
      expect((await running).stdout, 'real');
    });

    test('the app hanging up fails what it held, and nothing more goes to '
        'it', () async {
      adoptA();
      final running = runs.run('ssh:h1', request);
      runs.detach(appA);
      await expectLater(running, commandFails('closed before it answered'));
      expect(runs.connected, isFalse);
      await expectLater(
        runs.run('ssh:h1', request),
        commandFails(kRunsAppNotRunning),
      );
      expect(sentToA, hasLength(1));
    });

    test('another app hanging up changes nothing for the adopter', () async {
      adoptA();
      final running = runs.run('ssh:h1', request);
      runs.detach(appB);
      expect(runs.connected, isTrue);
      runs.answer(
        appA,
        RunResultMessage.ran(
          sentToA.single.callId,
          exitCode: 0,
          stdout: 'still here',
          stderr: '',
        ),
      );
      expect((await running).stdout, 'still here');
    });

    test('a second adopter replaces the first, whose calls fail', () async {
      adoptA();
      final held = runs.run('ssh:h1', request);
      adoptB();
      await expectLater(held, commandFails('replaced'));

      final next = runs.run('ssh:h1', request);
      expect(sentToA, hasLength(1));
      final call = sentToB.single;
      // The replaced app's late answer is not the new one's.
      runs.answer(
        appA,
        RunResultMessage.ran(call.callId, exitCode: 1, stdout: '', stderr: ''),
      );
      runs.answer(
        appB,
        RunResultMessage.ran(call.callId, exitCode: 0, stdout: 'B', stderr: ''),
      );
      expect((await next).stdout, 'B');
    });

    test('the same app offering again keeps its calls', () async {
      adoptA();
      final held = runs.run('ssh:h1', request);
      adoptA();
      runs.answer(
        appA,
        RunResultMessage.ran(
          sentToA.single.callId,
          exitCode: 0,
          stdout: 'kept',
          stderr: '',
        ),
      );
      expect((await held).stdout, 'kept');
    });

    test('closing fails every call in flight', () async {
      adoptA();
      final held = runs.run('ssh:h1', request);
      runs.close();
      await expectLater(held, commandFails('stopping'));
      expect(runs.connected, isFalse);
    });

    test('a forwarded runner holds no process open', () async {
      adoptA();
      await expectLater(
        ForwardedCommandRunner('ssh:h1', runs).start(request),
        commandFails('cannot hold a process open in ssh:h1'),
      );
      expect(sentToA, isEmpty);
    });
  });

  group('ServerRunnerFactory', () {
    final at = DateTime.utc(2026, 9, 26);

    test('an SSH environment is forwarded; this machine runs here', () {
      final factory = ServerRunnerFactory(ForwardedRuns());
      expect(factory.canReachRemote, isTrue);
      final ssh = factory.forEnvironment(
        ExecutionEnvironment(
          id: 'ssh:h1',
          kind: EnvironmentKind.ssh,
          name: 'box',
          createdAt: at,
        ),
      );
      expect(ssh, isA<ForwardedCommandRunner>());
      expect(ssh.environmentId, 'ssh:h1');
      expect(
        factory.forEnvironment(localHostEnvironment(at)),
        isNot(isA<ForwardedCommandRunner>()),
      );
    });
  });

  group('a command as JSON', () {
    test('every field round-trips', () {
      const full = CommandRequest(
        executable: '/usr/bin/env',
        arguments: ['sh', '-c', r'cat > "$1"', 'sh', '/tmp/x'],
        workingDirectory: EnvironmentPath(
          environmentId: 'ssh:h1',
          path: '/home/dev/src',
        ),
        runInShell: true,
        stdinText: 'the file\'s text\n',
        timeout: Duration(seconds: 42),
        environment: {'LANG': 'C', 'EMPTY': ''},
        removedEnvironment: {'ANTHROPIC_API_KEY', 'OPENAI_API_KEY'},
      );
      final back = commandRequestFromJson(commandRequestToJson(full));
      expect(back.executable, full.executable);
      expect(back.arguments, full.arguments);
      expect(back.workingDirectory, full.workingDirectory);
      expect(back.runInShell, isTrue);
      expect(back.stdinText, full.stdinText);
      expect(back.timeout, full.timeout);
      expect(back.environment, full.environment);
      expect(back.removedEnvironment, full.removedEnvironment);
    });

    test('a bare command carries only what it has', () {
      final json = commandRequestToJson(request);
      expect(json.keys.toSet(), {'executable', 'arguments'});
      final back = commandRequestFromJson(json);
      expect(back.workingDirectory, isNull);
      expect(back.runInShell, isFalse);
      expect(back.stdinText, isNull);
      expect(back.timeout, isNull);
      expect(back.environment, isEmpty);
      expect(back.removedEnvironment, isEmpty);
    });

    test('something that is not a command is a FormatException', () {
      expect(
        () => commandRequestFromJson({'arguments': <Object?>[]}),
        throwsFormatException,
      );
      expect(
        () => commandRequestFromJson({'executable': 'x', 'arguments': 'no'}),
        throwsFormatException,
      );
    });
  });

  test('a call with a timeout still fails when the server stops', () {
    // Its bound (the timeout plus ten seconds) wraps the call; the failure
    // of the call underneath still comes through it.
    final runs = ForwardedRuns()..adopt(Object(), (_) {});
    final bounded = runs.run(
      'ssh:h1',
      const CommandRequest(executable: 'x', timeout: Duration(seconds: 1)),
    );
    runs.close();
    return expectLater(bounded, commandFails('stopping'));
  });
}
