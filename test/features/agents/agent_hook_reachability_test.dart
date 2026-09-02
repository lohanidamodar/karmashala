import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/features/agents/application/agent_hook_reachability.dart';
import 'package:karmashala/src/features/agents/domain/agent_hook_endpoint.dart';
import 'package:karmashala/src/features/environments/domain/environment_kind.dart';
import 'package:karmashala/src/features/environments/domain/execution_environment.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';

void main() {
  const bound = AgentHookEndpoint(
    port: 4242,
    token: 'tok',
    wslHost: '172.18.240.1',
  );
  final wsl = wslEnv();

  AgentHookReachability probeThat(
    CommandResult Function(CommandRequest request) responder, {
    Object? throwError,
  }) {
    final runner = FakeCommandRunner(
      environmentId: wsl.id,
      responder: responder,
      throwError: throwError,
    );
    return AgentHookReachability(
      runners: FakeCommandRunnerFactory(byEnvironmentId: {wsl.id: runner}),
    );
  }

  CommandResult printing(String stdout) =>
      CommandResult(exitCode: 0, stdout: stdout, stderr: '');

  test('a door that answers at all is reachable, whatever it answers', () async {
    // 401 is the honest answer to an unauthenticated probe, and it proves the
    // door exactly as well as 200 would — which is why the probe carries no
    // token.
    for (final code in ['401', '200', '404', '500']) {
      expect(
        await probeThat((_) => printing(code)).answersFrom(wsl, bound),
        isTrue,
        reason: 'curl printed $code, so a server answered',
      );
    }
  });

  test('a bound address that never answers is not reachable', () async {
    // The owner's machine, exactly: the TCP handshake to 172.18.240.1
    // completed and every byte after it was reset, so curl printed 000. The
    // app used to read `reaches(wsl) == true` here and install four hooks.
    expect(
      await probeThat((_) => printing('000')).answersFrom(wsl, bound),
      isFalse,
    );
  });

  test('a distribution without curl is not reachable', () async {
    expect(
      await probeThat(
        (_) => const CommandResult(exitCode: 127, stdout: '', stderr: 'no curl'),
      ).answersFrom(wsl, bound),
      isFalse,
      reason:
          'the hook command this app installs is itself a curl, so a distro '
          'without one could never have delivered a callback either',
    );
  });

  test('an environment that cannot be run in at all is not reachable', () async {
    expect(
      await probeThat(
        (_) => printing('200'),
        throwError: CommandException('wsl.exe is not on this machine'),
      ).answersFrom(wsl, bound),
      isFalse,
    );
  });

  test('the probe dials the exact host:port the installer would write', () async {
    late CommandRequest seen;
    await probeThat((request) {
      seen = request;
      return printing('401');
    }).answersFrom(wsl, bound);

    expect(seen.executable, 'curl');
    expect(seen.arguments, contains('http://172.18.240.1:4242/agent-hook'));
    expect(
      seen.arguments,
      containsAllInOrder(['-m', '2']),
      reason:
          'a door too slow for the probe is too slow for the hook, which '
          'carries the same bound',
    );
    expect(
      seen.arguments.join(' '),
      isNot(contains('tok')),
      reason: 'the probe needs no credential and must not spend one',
    );
  });

  test('no address bound for the environment is not reachable', () async {
    const unbound = AgentHookEndpoint(port: 4242, token: 'tok');
    expect(
      await probeThat((_) => printing('200')).answersFrom(wsl, unbound),
      isFalse,
    );
  });

  test('local environments are trusted without spending a process', () async {
    final runner = FakeCommandRunner(environmentId: 'windows');
    final probe = AgentHookReachability(
      runners: FakeCommandRunnerFactory(fallback: runner),
    );
    final local = ExecutionEnvironment(
      id: 'windows',
      kind: EnvironmentKind.windowsNative,
      name: 'This PC',
      createdAt: testTime,
    );

    expect(await probe.answersFrom(local, bound), isTrue);
    expect(
      runner.requests,
      isEmpty,
      reason:
          'a local agent dials this very process\'s loopback, which it is '
          'listening on by construction',
    );
  });

  test('only three digits that are not 000 count as an answer', () {
    expect(AgentHookReachability.answered('401'), isTrue);
    expect(AgentHookReachability.answered(' 200 \n'), isTrue);
    expect(AgentHookReachability.answered('000'), isFalse);
    expect(AgentHookReachability.answered(''), isFalse);
    expect(AgentHookReachability.answered('curl: (7) refused'), isFalse);
  });
}
