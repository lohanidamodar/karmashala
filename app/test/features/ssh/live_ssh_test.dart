@Tags(['live-ssh'])
library;

import 'dart:io';

import 'package:karmashala/src/features/ssh/data/ssh_hosts_data.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_ssh/runner.dart';
import 'package:karmashala_core/util.dart';
import 'package:agent_cli/discovery.dart' hide Clock, SystemClock;
import 'package:karmashala/src/core/util/agent_cli_bridge.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_ssh/host.dart';
import 'package:karmashala_terminal_runtime/host_link.dart';
import 'package:karmashala_host/protocol.dart';
import 'package:karmashala_ssh/files.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// End-to-end tests against a **real** SSH server.
///
/// They are opt-in because CI has no remote host: set `KARMASHALA_SSH_HOST`,
/// `KARMASHALA_SSH_USER` and `KARMASHALA_SSH_KEY` (a local private key path)
/// to run them, plus `KARMASHALA_SSH_PORT` if it is not 22. Without those the
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
  final address = _env('KARMASHALA_SSH_HOST');
  final username = _env('KARMASHALA_SSH_USER');
  final keyPath = _env('KARMASHALA_SSH_KEY');
  final port = int.tryParse(_env('KARMASHALA_SSH_PORT') ?? '22') ?? 22;

  if (address == null || username == null || keyPath == null) {
    test(
      'live SSH tests are skipped',
      () {},
      skip:
          'Set KARMASHALA_SSH_HOST, KARMASHALA_SSH_USER and '
          'KARMASHALA_SSH_KEY to run the live SSH suite.',
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

  late FakeDataServer server;
  late KnownHostsData known;
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

  setUp(() async {
    server = FakeDataServer();
    known = KnownHostsData(await server.connect());
  });

  tearDown(() async {
    for (final connection in opened) {
      await connection.close();
    }
    opened.clear();
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
      server.knownHostRows.trust(
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
          arguments: [r'; id > /tmp/karmashala-pwned #'],
        ),
      );
      expect(result.stdout.trim(), r'; id > /tmp/karmashala-pwned #');
      final probe = await runner.run(
        const CommandRequest(
          executable: 'test',
          arguments: ['-e', '/tmp/karmashala-pwned'],
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
        clock: agentCliClock(const SystemClock()),
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

  group('deploying the session host', () {
    // The one thing no fake could ever answer, and the reason item 3 existed:
    // half a deploy is shell commands and half is SFTP, and only the shell
    // expands `$HOME`. Against a fake that expanded it for both, a deployer
    // that uploaded to a literal `$HOME/.karmashala/bin/…` was green for a day
    // while every pane on the owner's droplet silently fell back to tmux.
    //
    // It uploads ~7 MB and leaves `serve` running, which is exactly the state
    // the app expects to find; nothing here touches tmux.
    late HostBinarySource binaries;

    setUp(() {
      final directory = _env('KARMASHALA_HOST_BINARIES');
      binaries = directory == null
          ? DirectoryHostBinaries.standard()
          : DirectoryHostBinaries([Directory(directory)]);
    });

    test('resolves the remote home and installs under it', () async {
      final deployer = HostDeployer(
        target: SshHostDeployTarget(await trusted()),
        binaries: binaries,
      );

      final platform = await deployer.measurePlatform();
      expect(platform, isNotNull, reason: '`uname -sm` on $address');
      final binary = await binaries.binaryFor(platform!);
      if (binary == null) {
        // A self-skip that says what it looked for, never a silent pass (§18).
        // ignore: avoid_print
        print(
          '  skipped: no host binary for ${platform.targetKey} '
          '(set KARMASHALA_HOST_BINARIES to the directory holding them; '
          'this build has ${(await binaries.availableTargets()).join(', ')})',
        );
        return;
      }

      final home = await deployer.resolveHome();
      expect(
        home,
        isNotNull,
        reason: r'$HOME must be resolvable before anything is written',
      );
      expect(home, startsWith('/'));

      final deployment = await deployer.deploy();
      // ignore: avoid_print
      print('  ${deployment.status.name}: ${deployment.reason}');

      expect(
        deployment.status,
        HostDeploymentStatus.ready,
        reason: deployment.reason,
      );
      expect(deployment.remotePath, startsWith('$home/.karmashala/bin/'));
      expect(deployment.remotePath, isNot(contains(r'$')));
      expect(deployment.hostVersion, isNotNull);
      expect(deployment.protocolVersion, kProtocolVersion);

      // The file is really there, under the resolved path and executable.
      final listed = await SshHostDeployTarget(
        await trusted(),
      ).run('test -x ${deployment.remotePath} && echo executable');
      expect(listed.stdout, contains('executable'));
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('a pane can open a session on it and close it again', () async {
      final target = SshHostDeployTarget(await trusted());
      final deployment = await HostDeployer(
        target: target,
        binaries: binaries,
      ).deploy();
      if (deployment.status != HostDeploymentStatus.ready) {
        // ignore: avoid_print
        print('  skipped: ${deployment.status.name} — ${deployment.reason}');
        return;
      }

      final link = await HostPaneLink.open(
        await target.exec('${deployment.remotePath} attach'),
        clientId: 'live-ssh-test',
      );
      // A scratch id of our own, so this can never collide with a session a
      // real pane owns on that machine.
      final sessionId =
          'karmashala_live_test_${DateTime.now().millisecondsSinceEpoch}';
      try {
        final opened = await link.openSession(
          sessionId: sessionId,
          argv: const ['/bin/sh', '-l'],
          environment: const {'TERM': 'xterm-256color'},
          columns: 80,
          rows: 24,
        );
        expect(opened.sessionId, sessionId);
        // ignore: avoid_print
        print(
          '  attached: ${opened.sessionId} on ${link.welcome?.hostVersion}',
        );
        // Ended rather than left behind: this is a test's session, not a user's.
        await link.closeSession(sessionId);
      } finally {
        await link.close();
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('the session host, read and acted on from its card', () {
    // What no fake can answer about the explicit verbs: whether the listing
    // script reads a real `~/.karmashala/bin` the way the deployer wrote it,
    // whether `ps -o args=` names the running bundle in a form the version can
    // be read out of, and whether the tools question parses on that machine's
    // `sh`. **Nothing here uninstalls, and nothing stops a host that holds
    // sessions** — the box is somebody's, and its sessions are theirs.
    late HostBinarySource binaries;

    setUp(() {
      final directory = _env('KARMASHALA_HOST_BINARIES');
      binaries = directory == null
          ? DirectoryHostBinaries.standard()
          : DirectoryHostBinaries([Directory(directory)]);
    });

    Future<HostInstaller> installer() async => HostInstaller(
      host: host,
      deployer: HostDeployer(
        target: SshHostDeployTarget(await trusted()),
        binaries: binaries,
      ),
    );

    test('the reading agrees with what a deploy just put there', () async {
      final it = await installer();
      final before = await it.check();
      // ignore: avoid_print
      print('  before: ${before.label} — ${before.reason}');
      expect(
        before.state,
        isNot(HostInstallState.unknown),
        reason: before.reason,
      );
      if (!before.canInstall) {
        // ignore: avoid_print
        print('  skipped: this build carries no bundle for ${before.platform}');
        return;
      }

      final after = await it.install();
      // ignore: avoid_print
      print('  after install: ${after.label} — ${after.reason}');
      expect(after.deployment, isNull, reason: after.reason);
      expect(after.running, isTrue);
      expect(after.installedVersion, isNotNull);
      expect(after.remotePath, contains('/.karmashala/bin/karmashala_host-'));
      final exists = await SshHostDeployTarget(
        await trusted(),
      ).run('test -x ${after.remotePath} && echo executable');
      expect(exists.stdout, contains('executable'));
      // An older `serve` holding sessions is left alone, and then the label
      // says so rather than claiming this version runs.
      if (after.state == HostInstallState.installed) {
        expect(after.installedVersion, after.offeredVersion);
      } else {
        expect(after.state, HostInstallState.outdated);
        expect(after.sessionsHeld, isNot(0));
      }
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('Stop and Start, only on a host that holds nothing', () async {
      final it = await installer();
      final reading = await it.check();
      if (!reading.running || reading.sessionsHeld != 0) {
        // ignore: avoid_print
        print(
          '  skipped: ${reading.label}, holding '
          '${reading.sessionsHeld ?? 'an unknown number of'} session(s) — '
          'stopping it would end somebody\'s work',
        );
        return;
      }

      final stopped = await it.stop();
      expect(stopped.running, isFalse, reason: stopped.reason);
      expect(stopped.label, contains('(stopped)'));

      final started = await it.start();
      // ignore: avoid_print
      print('  ${started.label} — ${started.reason}');
      expect(started.running, isTrue, reason: started.reason);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('the `sudo -n` evidence is a word this understands — and nothing is '
        'changed to get it', () async {
      // Only the reading half of the port script: whether root, whether sudo
      // would prompt, which firewall is *running*. No rule is added here.
      final target = SshHostDeployTarget(await trusted());
      final said = await target.run(
        'if [ "\$(id -u)" = 0 ]; then echo root; '
        'elif sudo -n true 2>/dev/null; then echo passwordless; '
        'else echo needs-password; fi; '
        'command -v ufw >/dev/null 2>&1 && '
        "{ grep -q '^ENABLED=no' /etc/ufw/ufw.conf 2>/dev/null && echo ufw-off || echo ufw-on; }; "
        'command -v firewall-cmd >/dev/null 2>&1 && '
        '{ firewall-cmd --state >/dev/null 2>&1 && echo firewalld-on || echo firewalld-off; }; '
        'true',
      );
      // ignore: avoid_print
      print('  ${said.stdout.trim().split('\n').join(', ')}');
      expect(
        said.stdout,
        anyOf(
          contains('root'),
          contains('passwordless'),
          contains('needs-password'),
        ),
      );
    });
  });

  group('the relay on a box', () {
    // What no fake can answer: whether `setsid nohup … relay` stays up once
    // the SSH channel that launched it closes, whether the token file the box
    // minted is owner-only and readable back, what `ps -o args=` really prints
    // for the running path, and whether the health check under the token
    // answers from this computer. It takes a spare port and takes everything
    // away again, so a real relay on 8787 there is never touched.
    const livePort = 18787;
    late HostBinarySource binaries;

    setUp(() {
      final directory = _env('KARMASHALA_HOST_BINARIES');
      binaries = directory == null
          ? DirectoryHostBinaries.standard()
          : DirectoryHostBinaries([Directory(directory)]);
    });

    test('starts from the deployed bundle, answers under its token, and is '
        'removed without a trace', () async {
      final target = SshHostDeployTarget(await trusted());
      final deployment = await HostDeployer(
        target: target,
        binaries: binaries,
      ).deploy();
      final remotePath = deployment.remotePath;
      if (remotePath == null) {
        // ignore: avoid_print
        print('  skipped: ${deployment.status.name} — ${deployment.reason}');
        return;
      }
      final setup = SshRelaySetup(
        host: host,
        target: target,
        remotePath: remotePath,
        port: livePort,
      );
      try {
        final started = await setup.start();
        // ignore: avoid_print
        print('  ${started.status.name}: ${started.reason}');
        if (started.status == SshRelayStatus.cannotStart) {
          // A bundle from before `relay` existed: said, never a silent pass.
          // ignore: avoid_print
          print(
            '  skipped: the bundle in KARMASHALA_HOST_BINARIES has no relay command',
          );
          return;
        }
        expect(started.status, SshRelayStatus.running, reason: started.reason);
        expect(started.url!.host, host.host);
        expect(started.url!.path, startsWith('/k/'));
        expect(started.runningPath, remotePath);
        expect(started.reason, isNot(contains(started.url!.pathSegments[1])));

        // Owner-only, and not on any command line.
        final home = (await target.run(r'echo "$HOME"')).stdout.trim();
        final mode = await target.run(
          'stat -c %a $home/.karmashala/relay.token 2>/dev/null || '
          'stat -f %Lp $home/.karmashala/relay.token',
        );
        expect(mode.stdout.trim(), '600');
        final args = await target.run(
          'ps -o args= -p \$(cat $home/.karmashala/relay.pid)',
        );
        expect(args.stdout, isNot(contains(started.url!.pathSegments[1])));

        // Idempotent, and a second look agrees with the first.
        expect((await setup.start()).status, SshRelayStatus.running);
        expect((await setup.check()).status, SshRelayStatus.running);

        expect((await setup.stop()).status, SshRelayStatus.stopped);
        expect((await setup.check()).status, SshRelayStatus.stopped);
      } finally {
        final removed = await setup.remove();
        // ignore: avoid_print
        print('  ${removed.status.name}: ${removed.reason}');
        final left = await target.run(
          r'ls "$HOME/.karmashala" | grep -c "^relay\." || true',
        );
        expect(left.stdout.trim(), '0', reason: 'token, pid and log are gone');
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
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
