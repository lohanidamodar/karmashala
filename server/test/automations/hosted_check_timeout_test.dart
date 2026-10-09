import 'dart:async';
import 'dart:convert';

import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/checks.dart';
import 'package:karmashala_host/src/automations/hosted_check_runner.dart';
import 'package:karmashala_host/src/domain/session_registry.dart';
import 'package:karmashala_host/src/pty/fake_pty.dart';
import 'package:karmashala_host/src/pty/pty.dart';
import 'package:test/test.dart';

/// A check that never exits — a watch mode, a prompt, a hung socket — is
/// stopped at its time limit with everything it started, and recorded as
/// timed out with what it printed until then; a cancel stops it the same way.
void main() {
  const limit = Duration(milliseconds: 50);
  final check = ProjectCheck(
    id: 'k1',
    repositoryId: 'r1',
    name: 'watch',
    command: const ['npm', 'test'],
    createdAt: DateTime.utc(2026, 10, 9),
    timeLimit: limit,
  );
  const here = EnvironmentPath(environmentId: 'local', path: '/w');

  group('on this machine', () {
    late _DyingLauncher pty;
    late HostedCheckRunner runner;

    setUp(() {
      pty = _DyingLauncher();
      runner = HostedCheckRunner(
        registry: SessionRegistry(launcher: pty),
        newId: () => 'c1',
      );
    });

    test(
      'a check that never exits times out, killed, its output kept',
      () async {
        final ran = runner.execute(check, directory: here, title: 'watch');
        await Future<void>.delayed(Duration.zero);
        pty.handles.single.emit(utf8.encode('Watching for changes...\r\n'));
        final execution = await ran.timeout(const Duration(seconds: 5));
        expect(execution.timedOutAfter, limit);
        expect(execution.exitCode, isNull);
        expect(execution.refusal, isNull);
        expect(execution.transcript, contains('Watching for changes'));
        expect(pty.handles.single.signals, contains(9));
        expect(
          pty.started.single.environment[kCheckMarkerVariable],
          '${kCheckSessionPrefix}c1',
        );
      },
    );

    test('a check that exits in time is read as before', () async {
      final ran = runner.execute(
        check.withTimeLimit(const Duration(minutes: 30)),
        directory: here,
        title: 'watch',
      );
      await Future<void>.delayed(Duration.zero);
      pty.handles.single.finish(3);
      final execution = await ran;
      expect(execution.exitCode, 3);
      expect(execution.timedOutAfter, isNull);
    });

    test('a cancel ends it as cancelled, never as a verdict', () async {
      final cancel = Completer<void>();
      final ran = runner.execute(
        check.withTimeLimit(const Duration(minutes: 30)),
        directory: here,
        title: 'watch',
        cancelled: cancel.future,
      );
      await Future<void>.delayed(Duration.zero);
      cancel.complete();
      final execution = await ran.timeout(const Duration(seconds: 5));
      expect(execution.refusal, contains('cancelled'));
      expect(execution.timedOutAfter, isNull);
      expect(pty.handles.single.signals, contains(9));
    });
  });

  test('in WSL its Linux processes are killed by marker in the distribution, '
      'not only wsl.exe', () async {
    final pty = _DyingLauncher();
    final distro = _Box(environmentId: 'wsl1');
    final runner = HostedCheckRunner(
      registry: SessionRegistry(launcher: pty),
      newId: () => 'c1',
      environmentOf: (id) => ExecutionEnvironment(
        id: id,
        kind: EnvironmentKind.wsl,
        name: 'Ubuntu',
        wslDistribution: 'Ubuntu',
        createdAt: DateTime.utc(2026, 10, 9),
      ),
      distroRunner: (_) => distro,
    );
    final execution = await runner
        .execute(
          check,
          directory: const EnvironmentPath(environmentId: 'wsl1', path: '/w'),
          title: 'watch',
        )
        .timeout(const Duration(seconds: 5));
    expect(execution.timedOutAfter, limit);
    final started = pty.started.single;
    expect(started.environment['WSLENV'], contains('$kCheckMarkerVariable/u'));
    final kill = distro.requests.single;
    expect(kill.executable, 'sh');
    expect(kill.arguments.last, contains('${kCheckSessionPrefix}c1'));
    expect(pty.handles.single.signals, contains(9));
  });

  test('on an SSH box the command is killed by marker and what it printed '
      'is kept', () async {
    final box = _Box(environmentId: 'ssh:h1');
    final runner = HostedCheckRunner(
      registry: SessionRegistry(launcher: _DyingLauncher()),
      newId: () => 'c1',
      remote: (_) => box,
    );
    final execution = await runner
        .execute(
          check,
          directory: const EnvironmentPath(environmentId: 'ssh:h1', path: '/w'),
          title: 'watch',
        )
        .timeout(const Duration(seconds: 5));
    expect(execution.timedOutAfter, limit);
    expect(execution.transcript, contains('Watching'));
    final [command, kill] = box.requests;
    expect(
      command.environment[kCheckMarkerVariable],
      '${kCheckSessionPrefix}c1',
    );
    expect(kill.arguments.last, contains('${kCheckSessionPrefix}c1'));
  });

  test('the kill script matches the marker exactly, quoted', () {
    final script = checkTreeKillScript("x'y");
    expect(script, contains(r"'KARMASHALA_CHECK_ID=x'\''y'"));
    expect(script, contains('grep -laxzF'));
  });
}

/// A launcher whose children die when killed, as real ones do.
class _DyingLauncher extends FakePtyLauncher {
  @override
  PtyHandle start(PtySpawnRequest request) {
    started.add(request);
    final handle = _DyingHandle(nextPid++, request);
    handles.add(handle);
    return handle;
  }
}

class _DyingHandle extends FakePtyHandle {
  _DyingHandle(super.pid, super.request);

  @override
  void kill([int signal = 15]) {
    super.kill(signal);
    finish(128 + signal);
  }
}

/// A machine whose check never ends until the kill script runs, then reports
/// what it printed, as SSH does for a killed command.
class _Box implements CommandRunner {
  _Box({required this.environmentId});

  @override
  final String environmentId;
  final requests = <CommandRequest>[];
  final _check = Completer<CommandResult>();

  @override
  Future<CommandResult> run(CommandRequest request) {
    requests.add(request);
    if (request.executable == 'sh') {
      if (!_check.isCompleted) {
        _check.complete(
          const CommandResult(exitCode: 137, stdout: 'Watching\n', stderr: ''),
        );
      }
      return Future.value(
        const CommandResult(exitCode: 0, stdout: '', stderr: ''),
      );
    }
    return _check.future;
  }

  @override
  Future<ProcessHandle> start(CommandRequest request) =>
      Future.error(CommandException('nothing is started in a test'));
}
