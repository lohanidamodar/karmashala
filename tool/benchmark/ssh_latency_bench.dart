import 'dart:io';

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/core/process/ssh_command_runner.dart';
import 'package:karmashala/src/core/process/local_command_runner.dart';
import 'package:karmashala/src/core/process/wsl_command_runner.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala/src/features/agents/data/agent_discovery_service.dart';
import 'package:karmashala/src/features/environments/data/environment_discovery_service.dart';
import 'package:karmashala/src/features/environments/domain/environment_kind.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/environments/domain/execution_environment.dart';
import 'package:karmashala/src/features/ssh/data/known_host_dao.dart';
import 'package:karmashala/src/features/ssh/data/ssh_connection.dart';
import 'package:karmashala/src/features/ssh/data/ssh_host_key_verifier.dart';
import 'package:karmashala/src/features/ssh/domain/ssh_host.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../test/support/fakes.dart';
import '../../test/support/fixtures.dart';

/// Benchmark — NOT part of `flutter test`'s default run. It lives under `tool/`
/// so that discovery never picks it up. Run it on demand:
///
///   flutter test tool/benchmark/ssh_latency_bench.dart
///
/// Reports what an SSH round trip costs against the same work done locally in
/// WSL through `WslCommandRunner` — same shell, same binaries, only the
/// transport differs — and then whether the per-command cost is round trips or
/// client-side crypto, by running ten commands serially against ten
/// concurrently.
///
/// Timings are printed, not asserted. Wall clock over a network to a machine
/// this program does not control is far too noisy to gate on: the only thing it
/// can honestly claim is that the work happened, which is why it sat in the
/// test namespace asserting "measured time is greater than zero" until Loop 69
/// moved it here beside `paint_bench.dart`.
///
/// Needs the same environment as the live SSH suite:
/// `KARMASHALA_SSH_HOST`, `KARMASHALA_SSH_USER`, `KARMASHALA_SSH_KEY`, and
/// `KARMASHALA_SSH_PORT` if it is not 22. Without them it skips with a reason
/// rather than passing.
String? _env(String name) {
  final value = Platform.environment[name];
  return value == null || value.isEmpty ? null : value;
}

void main() {
  final address = _env('KARMASHALA_SSH_HOST');
  final username = _env('KARMASHALA_SSH_USER');
  final keyPath = _env('KARMASHALA_SSH_KEY');
  final port = int.tryParse(_env('KARMASHALA_SSH_PORT') ?? '22') ?? 22;

  if (address == null || username == null || keyPath == null) {
    test(
      'SSH latency benchmark',
      () {},
      skip:
          'Set KARMASHALA_SSH_HOST, KARMASHALA_SSH_USER and '
          'KARMASHALA_SSH_KEY to run the SSH latency benchmark.',
    );
    return;
  }

  final host = SshHost(
    id: 'live',
    name: 'live-target',
    host: address,
    port: port,
    username: username,
    authMethod: SshAuthMethod.privateKey,
    privateKey: EnvironmentPath(environmentId: 'windows', path: keyPath),
    createdAt: testTime,
  );

  final environment = ExecutionEnvironment(
    id: host.environmentId,
    kind: EnvironmentKind.ssh,
    name: host.name,
    sshHostId: host.id,
    createdAt: testTime,
  );

  late AppDatabase db;
  late KnownHostDao known;
  final opened = <SshConnection>[];

  SshConnection connect() {
    final connection = SshConnection(
      host: host,
      verifier: SshHostKeyVerifier(
        knownHosts: known,
        host: host.host,
        port: host.port,
        clock: const SystemClock(),
        onUnknownHostKey: (_) => true,
      ),
      connectTimeout: const Duration(seconds: 10),
    );
    opened.add(connection);
    return connection;
  }

  setUp(() {
    db = AppDatabase.memory();
    known = KnownHostDao(db);
  });

  tearDown(() async {
    for (final connection in opened) {
      await connection.close();
    }
    opened.clear();
    db.close();
  });

  test('SSH round trips versus the same work locally', () async {
    final connection = connect();
    await connection.client();
    final ssh = SshCommandRunner(
      environmentId: environment.id,
      connection: connection,
    );

    // The local comparison runs the identical commands in a WSL distribution
    // through WslCommandRunner: same shell, same binaries, only the transport
    // differs.
    final locals = await EnvironmentDiscoveryService(
      host: const LocalCommandRunner(),
      clock: const SystemClock(),
    ).discover();
    final distro = locals
        .where((e) => e.kind == EnvironmentKind.wsl)
        .map((e) => e.wslDistribution!)
        .firstOrNull;
    final wsl = distro == null
        ? null
        : WslCommandRunner(environmentId: 'wsl:$distro', distribution: distro);

    Future<double> timeMedian(
      CommandRunner runner,
      Future<void> Function(CommandRunner) work, {
      int samples = 7,
    }) async {
      final timings = <int>[];
      for (var i = 0; i < samples; i++) {
        final watch = Stopwatch()..start();
        await work(runner);
        timings.add(watch.elapsedMicroseconds);
      }
      timings.sort();
      return timings[timings.length ~/ 2] / 1000;
    }

    Future<void> trivial(CommandRunner r) async {
      await r.run(const CommandRequest(executable: 'true'));
    }

    Future<void> discovery(CommandRunner r) async {
      await AgentDiscoveryService(
        runner: r,
        environment: environment,
        ids: SequentialIdGenerator(),
        clock: const SystemClock(),
      ).probeAll();
    }

    Future<void> gitStatus(CommandRunner r) async {
      await r.run(
        const CommandRequest(
          executable: 'git',
          arguments: ['status', '--porcelain'],
          workingDirectory: EnvironmentPath(
            environmentId: 'ssh:live',
            path: '/tmp',
          ),
        ),
      );
    }

    final cold = Stopwatch()..start();
    final fresh = connect();
    await fresh.client();
    cold.stop();

    final results = <String, List<double?>>{
      'one trivial command': [
        await timeMedian(ssh, trivial),
        wsl == null ? null : await timeMedian(wsl, trivial),
      ],
      'agent discovery (3 agents)': [
        await timeMedian(ssh, discovery, samples: 5),
        wsl == null ? null : await timeMedian(wsl, discovery, samples: 5),
      ],
      'git status': [
        await timeMedian(ssh, gitStatus, samples: 5),
        wsl == null ? null : await timeMedian(wsl, gitStatus, samples: 5),
      ],
    };

    // ignore: avoid_print
    print('  cold connect (TCP + kex + auth): ${cold.elapsedMilliseconds} ms');
    // ignore: avoid_print
    print(
      '  ${'work'.padRight(28)} ${'ssh'.padLeft(9)} '
      '${'local'.padLeft(9)}  ratio',
    );
    results.forEach((label, values) {
      final remote = values[0]!;
      final local = values[1];
      final ratio = local == null || local == 0
          ? 'n/a'
          : '${(remote / local).toStringAsFixed(1)}x';
      // ignore: avoid_print
      print(
        '  ${label.padRight(28)} '
        '${remote.toStringAsFixed(1).padLeft(6)} ms '
        '${(local?.toStringAsFixed(1) ?? '-').padLeft(6)} ms  $ratio',
      );
    });

    // Is the per-command cost round trips or client-side crypto? Ten commands
    // run one after another versus all at once answers it: if the concurrent
    // batch is far cheaper, the cost is latency and batching or parallelism is
    // the fix; if it is not, the cost is CPU in the client.
    Future<int> sequential(int n) async {
      final watch = Stopwatch()..start();
      for (var i = 0; i < n; i++) {
        await ssh.run(const CommandRequest(executable: 'true'));
      }
      return watch.elapsedMilliseconds;
    }

    Future<int> concurrent(int n) async {
      final watch = Stopwatch()..start();
      await Future.wait([
        for (var i = 0; i < n; i++)
          ssh.run(const CommandRequest(executable: 'true')),
      ]);
      return watch.elapsedMilliseconds;
    }

    final serial = await sequential(10);
    final parallel = await concurrent(10);
    // ignore: avoid_print
    print(
      '  10 commands sequentially:   $serial ms '
      '(${(serial / 10).toStringAsFixed(1)} ms each)',
    );
    // ignore: avoid_print
    print(
      '  10 commands concurrently:   $parallel ms '
      '(${(parallel / 10).toStringAsFixed(1)} ms each)',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
}
