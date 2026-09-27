@Tags(['live-ssh'])
library;

import 'dart:io';

import 'package:karmashala/src/features/ssh/data/ssh_hosts_data.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_ssh_host/host.dart';
import 'package:karmashala_terminal_runtime/host_link.dart';
import 'package:karmashala_host/protocol.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_data_server.dart';
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

  // The transport itself — host keys, the runner, the connection's life,
  // agent discovery and SFTP — is `karmashala_ssh`'s live suite (slice 3a);
  // what stays here is what the app still does on a box: deploy, the host's
  // card and the relay.
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
}
