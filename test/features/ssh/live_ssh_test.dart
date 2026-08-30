@Tags(['live-ssh'])
library;

import 'dart:io';

import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/process/command_runner.dart';
import 'package:chitragupta/src/core/process/ssh_command_runner.dart';
import 'package:chitragupta/src/core/util/clock.dart';
import 'package:chitragupta/src/features/agents/data/agent_discovery_service.dart';
import 'package:chitragupta/src/features/agents/domain/agent_ids.dart';
import 'package:chitragupta/src/features/environments/domain/environment_kind.dart';
import 'package:chitragupta/src/features/environments/domain/environment_path.dart';
import 'package:chitragupta/src/features/environments/domain/execution_environment.dart';
import 'package:chitragupta/src/features/ssh/data/known_host_dao.dart';
import 'package:chitragupta/src/features/ssh/data/remote_file_browser.dart';
import 'package:chitragupta/src/features/ssh/data/ssh_connection.dart';
import 'package:chitragupta/src/features/ssh/data/ssh_host_key_verifier.dart';
import 'package:chitragupta/src/features/ssh/domain/ssh_connection_state.dart';
import 'package:chitragupta/src/features/ssh/domain/ssh_host.dart';
import 'package:chitragupta/src/features/ssh/domain/ssh_host_key.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// End-to-end tests against a **real** SSH server.
///
/// They are opt-in because CI has no remote host: set `CHITRAGUPTA_SSH_HOST`,
/// `CHITRAGUPTA_SSH_USER` and `CHITRAGUPTA_SSH_KEY` (a local private key path)
/// to run them, plus `CHITRAGUPTA_SSH_PORT` if it is not 22. Without those the
/// group is skipped rather than faked — a mock cannot tell you whether the
/// handshake, the shell quoting or the SFTP subsystem actually work.
///
/// A WSL distribution running `sshd` on a spare port is a good target: it is a
/// genuinely different machine as far as sockets, filesystems and PATH are
/// concerned.
///
/// The latency measurements that used to live at the bottom of this file are
/// now `tool/benchmark/ssh_latency_bench.dart`. They asserted only that the
/// numbers they printed were greater than zero, which is not a test; they take
/// the same environment variables and run on demand.
String? _env(String name) {
  final value = Platform.environment[name];
  return value == null || value.isEmpty ? null : value;
}

void main() {
  final address = _env('CHITRAGUPTA_SSH_HOST');
  final username = _env('CHITRAGUPTA_SSH_USER');
  final keyPath = _env('CHITRAGUPTA_SSH_KEY');
  final port = int.tryParse(_env('CHITRAGUPTA_SSH_PORT') ?? '22') ?? 22;

  if (address == null || username == null || keyPath == null) {
    test(
      'live SSH tests are skipped',
      () {},
      skip:
          'Set CHITRAGUPTA_SSH_HOST, CHITRAGUPTA_SSH_USER and '
          'CHITRAGUPTA_SSH_KEY to run the live SSH suite.',
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

  SshConnection connect({
    HostKeyTrustDecision? onUnknownHostKey,
    int maxAttempts = 2,
  }) {
    final connection = SshConnection(
      host: host,
      verifier: SshHostKeyVerifier(
        knownHosts: known,
        host: host.host,
        port: host.port,
        clock: const SystemClock(),
        onUnknownHostKey: onUnknownHostKey,
      ),
      maxAttempts: maxAttempts,
      connectTimeout: const Duration(seconds: 10),
    );
    opened.add(connection);
    return connection;
  }

  /// A connection that has already trusted the server, for the tests that are
  /// about something other than host keys.
  Future<SshConnection> trusted() async {
    final connection = connect(onUnknownHostKey: (_) => true);
    await connection.client();
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

  group('host key verification', () {
    test('first connection asks, then pins the key', () async {
      HostKeyPresentation? asked;
      final connection = connect(
        onUnknownHostKey: (p) {
          asked = p;
          return true;
        },
      );
      await connection.client();

      expect(asked, isNotNull, reason: 'a new host must be a user decision');
      expect(asked!.verdict, HostKeyVerdict.unknown);
      expect(asked!.fingerprint, startsWith('SHA256:'));
      expect(connection.isConnected, isTrue);

      final pinned = known.find(host.host, host.port)!;
      expect(pinned.fingerprint, asked!.fingerprint);
      // ignore: avoid_print
      print('  trusted ${pinned.keyType} ${pinned.fingerprint}');
    });

    test('a pinned key connects without asking again', () async {
      await (await trusted()).client();
      var asked = false;
      final second = connect(
        onUnknownHostKey: (_) {
          asked = true;
          return true;
        },
      );
      await second.client();
      expect(asked, isFalse);
      expect(second.isConnected, isTrue);
    });

    test('a changed key is refused, and never offered to the user', () async {
      // Pin a fingerprint the server cannot possibly present.
      known.trust(
        KnownHostKey(
          host: host.host,
          port: host.port,
          keyType: 'ssh-ed25519',
          fingerprint: 'SHA256:${'A' * 43}',
          trustedAt: testTime,
        ),
      );

      var asked = false;
      final connection = connect(
        onUnknownHostKey: (_) {
          asked = true;
          return true; // Would accept anything — must not be consulted.
        },
      );

      await expectLater(
        connection.client(),
        throwsA(
          isA<SshConnectionException>()
              .having((e) => e.message, 'message', contains('HAS CHANGED'))
              .having((e) => e.retryable, 'retryable', isFalse)
              .having((e) => e.cause, 'cause', isA<HostKeyRejected>()),
        ),
      );
      expect(asked, isFalse);
      expect(connection.isConnected, isFalse);
      expect(connection.state.status, SshConnectionStatus.failed);
      // The pinned key is untouched, so this is not a one-off refusal.
      expect(known.find(host.host, host.port)!.fingerprint, endsWith('AAA'));
    });

    test('an unknown host with no decision handler is refused', () async {
      final connection = connect();
      await expectLater(
        connection.client(),
        throwsA(isA<SshConnectionException>()),
      );
      expect(known.find(host.host, host.port), isNull);
    });
  });

  group('SshCommandRunner', () {
    late SshCommandRunner runner;

    setUp(() async {
      runner = SshCommandRunner(
        environmentId: environment.id,
        connection: await trusted(),
      );
    });

    test('runs a command and captures stdout and the exit code', () async {
      final result = await runner.run(
        const CommandRequest(executable: 'echo', arguments: ['hello remote']),
      );
      expect(result.exitCode, 0);
      expect(result.stdout.trim(), 'hello remote');
    });

    test(
      'reports a non-zero exit code as a result, not an exception',
      () async {
        final result = await runner.run(
          const CommandRequest(executable: 'false'),
        );
        expect(result.ok, isFalse);
        expect(result.exitCode, isNot(0));
      },
    );

    test('stderr is captured separately', () async {
      final result = await runner.run(
        const CommandRequest(
          executable: 'sh',
          arguments: ['-c', 'echo out; echo err >&2'],
        ),
      );
      expect(result.stdout.trim(), 'out');
      expect(result.stderr.trim(), 'err');
    });

    test('an argument cannot inject a second command', () async {
      final result = await runner.run(
        const CommandRequest(
          executable: 'echo',
          arguments: [r'; id > /tmp/chitragupta-pwned #'],
        ),
      );
      expect(result.stdout.trim(), r'; id > /tmp/chitragupta-pwned #');
      final probe = await runner.run(
        const CommandRequest(
          executable: 'test',
          arguments: ['-e', '/tmp/chitragupta-pwned'],
        ),
      );
      expect(probe.ok, isFalse, reason: 'the injected redirect must not run');
    });

    test('the working directory is honoured', () async {
      final result = await runner.run(
        const CommandRequest(
          executable: 'pwd',
          workingDirectory: EnvironmentPath(
            environmentId: 'ssh:live',
            path: '/etc',
          ),
        ),
      );
      expect(result.stdout.trim(), '/etc');
    });

    test(
      'a missing working directory fails instead of running elsewhere',
      () async {
        final result = await runner.run(
          const CommandRequest(
            executable: 'pwd',
            workingDirectory: EnvironmentPath(
              environmentId: 'ssh:live',
              path: '/no/such/directory',
            ),
          ),
        );
        expect(result.ok, isFalse);
      },
    );

    test('start() streams a long-lived process', () async {
      final handle = await runner.start(
        const CommandRequest(
          executable: 'sh',
          arguments: ['-c', 'echo one; echo two; sleep 0.2; echo three'],
        ),
      );
      final lines = await handle.stdoutLines.take(3).toList();
      expect(lines, ['one', 'two', 'three']);
      expect(await handle.exitCode, 0);
    });
  });

  group('connection lifecycle', () {
    test(
      'a dropped connection is reported, then transparently reconnected',
      () async {
        final connection = await trusted();
        final states = <SshConnectionState>[];
        connection.states.listen(states.add);
        final runner = SshCommandRunner(
          environmentId: environment.id,
          connection: connection,
        );

        expect(
          (await runner.run(const CommandRequest(executable: 'true'))).ok,
          isTrue,
        );

        // Hang up the way a server or a network would.
        final live = await connection.client();
        await live.close();
        await Future<void>.delayed(const Duration(milliseconds: 200));

        expect(connection.isConnected, isFalse);
        expect(
          states.map((s) => s.status),
          contains(SshConnectionStatus.disconnected),
        );

        // The next command reconnects rather than reporting a hollow success.
        final after = await runner.run(
          const CommandRequest(executable: 'echo', arguments: ['back']),
        );
        expect(after.stdout.trim(), 'back');
        expect(connection.isConnected, isTrue);
      },
    );

    test(
      'a wide fan-out queues instead of exhausting the session limit',
      () async {
        // 24 at once is well past OpenSSH's MaxSessions default of 10; without
        // the channel limiter this fails with "open failed".
        final runner = SshCommandRunner(
          environmentId: environment.id,
          connection: await trusted(),
        );
        final results = await Future.wait([
          for (var i = 0; i < 24; i++)
            runner.run(
              CommandRequest(executable: 'echo', arguments: ['probe-$i']),
            ),
        ]);
        expect(results.every((r) => r.ok), isTrue);
        expect(results.map((r) => r.stdout.trim()).toSet(), hasLength(24));
      },
    );

    test(
      'commands fail loudly once the connection is closed for good',
      () async {
        final connection = await trusted();
        final runner = SshCommandRunner(
          environmentId: environment.id,
          connection: connection,
        );
        await connection.close();
        await expectLater(
          runner.run(const CommandRequest(executable: 'true')),
          throwsA(isA<CommandException>()),
        );
      },
    );
  });

  group('agent discovery', () {
    test('finds a remote agent through the ordinary registry path', () async {
      final runner = SshCommandRunner(
        environmentId: environment.id,
        connection: await trusted(),
      );
      final found = await AgentDiscoveryService(
        runner: runner,
        environment: environment,
        ids: SequentialIdGenerator(),
        clock: const SystemClock(),
      ).discover();

      for (final installation in found) {
        // ignore: avoid_print
        print(
          '  found ${installation.agentId} ${installation.version} at '
          '${installation.executable.path}',
        );
        expect(installation.executable.environmentId, 'ssh:live');
        expect(installation.executable.path, startsWith('/'));
      }
      expect(
        found.map((i) => i.agentId),
        contains(AgentIds.claudeCode),
        reason: 'this suite expects Claude Code installed on the remote host',
      );
    });
  });

  group('remote file browsing over SFTP', () {
    late RemoteFileBrowser browser;

    setUp(() async {
      browser = RemoteFileBrowser(
        connection: await trusted(),
        environmentId: environment.id,
      );
    });
    tearDown(() => browser.close());

    test('resolves the remote home directory', () async {
      final home = await browser.home();
      expect(home.environmentId, 'ssh:live');
      expect(home.path, startsWith('/'));
    });

    test('lists a directory with types, directories first', () async {
      final entries = await browser.list(
        const EnvironmentPath(environmentId: 'ssh:live', path: '/etc'),
      );
      expect(entries, isNotEmpty);
      expect(entries.map((e) => e.name), contains('hostname'));
      final firstFile = entries.indexWhere((e) => !e.isDirectory);
      final lastDirectory = entries.lastIndexWhere((e) => e.isDirectory);
      if (firstFile != -1 && lastDirectory != -1) {
        expect(lastDirectory, lessThan(firstFile));
      }
      final hostname = entries.firstWhere((e) => e.name == 'hostname');
      expect(hostname.path.path, '/etc/hostname');
      expect(hostname.path.environmentId, 'ssh:live');
      expect(hostname.sizeBytes, greaterThan(0));
    });

    test('refuses to browse a path that belongs to another environment', () {
      expect(
        () => browser.list(
          const EnvironmentPath(environmentId: 'windows', path: r'C:\src'),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a missing directory is an error, not an empty listing', () {
      expect(
        () => browser.list(
          const EnvironmentPath(
            environmentId: 'ssh:live',
            path: '/no/such/directory',
          ),
        ),
        throwsA(isA<RemoteBrowseException>()),
      );
    });
  });
}
