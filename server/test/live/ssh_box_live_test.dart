@Tags(['live'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/ssh.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/ssh/ssh_domain.dart';
import 'package:karmashala_host/src/terminals/server_terminals.dart';
import 'package:karmashala_host_protocol/host_access.dart';
import 'package:karmashala_ssh_host/host.dart' show DirectoryHostBinaries;
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import '../serve/pipe_connection.dart';

/// **The host on a real SSH box, driven by the server** (slice 5d; moved
/// from the app's `live_ssh_test`'s deploy, card and relay half): the bundle
/// deployed with `ssh.deploy`, a terminal opened on the box and read here, a
/// client's attachment relayed frame by frame, and the relay on the box set
/// up and taken away — with no app.
///
/// Opt-in: `KARMASHALA_SSH_HOST`, `KARMASHALA_SSH_USER`, `KARMASHALA_SSH_KEY`
/// (a private key path on this machine), `KARMASHALA_SSH_PORT` when not 22,
/// and `KARMASHALA_HOST_BINARIES`, the folder holding the box's
/// `karmashala_host-<version>-linux-*.tar.gz` (PROJECT.md §18). The store is
/// in memory; the box's `~/.karmashala` is the one thing written.
String? _env(String name) {
  final value = Platform.environment[name];
  return value == null || value.isEmpty ? null : value;
}

void main() {
  final address = _env('KARMASHALA_SSH_HOST');
  final username = _env('KARMASHALA_SSH_USER');
  final keyPath = _env('KARMASHALA_SSH_KEY');
  final bundles = _env('KARMASHALA_HOST_BINARIES');
  final port = int.tryParse(_env('KARMASHALA_SSH_PORT') ?? '22') ?? 22;

  if (address == null ||
      username == null ||
      keyPath == null ||
      bundles == null) {
    test(
      'live box tests are skipped',
      () {},
      skip:
          'Set KARMASHALA_SSH_HOST, KARMASHALA_SSH_USER, KARMASHALA_SSH_KEY '
          'and KARMASHALA_HOST_BINARIES to run the server\'s live box suite.',
    );
    return;
  }

  final now = DateTime.now().toUtc();
  final host = SshHost(
    id: 'live',
    name: 'live-target',
    host: address,
    port: port,
    username: username,
    authMethod: SshAuthMethod.privateKey,
    privateKey: EnvironmentPath(
      environmentId: localHostEnvironmentId,
      path: keyPath,
    ),
    createdAt: now,
  );

  late AppDatabase db;
  late DataService data;
  late ServerSshDomain ssh;
  late DataSession window;

  setUp(() {
    db = AppDatabase.memory();
    data = DataService(db)..ensureEnvironment(localHostEnvironment(now));
    ssh = ServerSshDomain(
      data: data,
      database: db,
      dataDirectory: Directory.systemTemp.path,
      bundles: DirectoryHostBinaries([Directory(bundles)]),
    )..attach();
    // A desktop window trusts the key when asked.
    window = data.open((batch) {
      for (final change in batch.changes) {
        if (change is SshPromptOpened && change.kind == SshPromptKind.hostKey) {
          window.handleLater(SshAnswerPrompt(change.promptId, trust: true));
        }
      }
    });
    window.handle(const DataSubscribe());
    window.handle(SshHostPut(host));
  });

  tearDown(() async {
    await ssh.close();
    db.close();
  });

  ExecutionEnvironment box() =>
      data.environments.firstWhere((e) => e.id == host.environmentId);

  test('ssh.deploy installs the bundle, and a look then agrees', () async {
    final installed = (await window.handleLater(
      const SshDeploy('live', SshDeployAction.install),
    )).value;
    expect(
      installed.state,
      HostInstallState.installed,
      reason: installed.reason,
    );
    expect(installed.running, isTrue, reason: installed.reason);
    final looked = (await window.handleLater(
      const SshDeploy('live', SshDeployAction.check),
    )).value;
    expect(looked.state, HostInstallState.installed);
    expect(looked.remotePath, installed.remotePath);
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('a terminal opens on the box, its screen read here, and a client is '
      'relayed its frames', () async {
    final terminals = ServerTerminals(
      registry: SessionRegistry(launcher: FakePtyLauncher()),
      environments: () => data.environments,
      tell: (_) {},
      windows: false,
      remote: ssh.remote,
    );
    final opened = await terminals.openAnywhere(
      TerminalOpen(
        paneId: 'live-${now.millisecondsSinceEpoch}',
        environmentId: box().id,
        columns: 100,
        rows: 30,
      ),
    );
    expect(opened.sessionId, startsWith('ssh:live/'));

    final local = HostServer(
      registry: SessionRegistry(launcher: FakePtyLauncher()),
      ptyLibrary: 'fake',
    )..boxes = ssh.relay;
    final (client, served) = PipeEnd.pair();
    unawaited(local.serveConnection(served));
    final parser = FrameParser();
    final seen = <HostMessage>[];
    client.incoming.listen(
      (chunk) => seen.addAll(parser.add(chunk).map(decodeMessage)),
    );
    client
      ..add(
        const HelloMessage(
          requestId: 1,
          clientId: 'live-window',
        ).toFrame().encode(),
      )
      ..add(
        AttachMessage(
          requestId: 2,
          sessionId: opened.sessionId,
          sinceOffset: 0,
          claimWrite: true,
        ).toFrame().encode(),
      );
    Future<void> until(bool Function() ready) async {
      for (var i = 0; i < 400 && !ready(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }

    await until(() => seen.any((m) => m is AttachedMessage));
    final attached = seen.whereType<AttachedMessage>().single;
    client.add(
      InputMessage(
        attached.sessionRef,
        Uint8List.fromList(utf8.encode('echo karmashala-5d-\$((6*7))\r')),
      ).toFrame().encode(),
    );
    String text() => utf8.decode([
      for (final m in seen)
        if (m is OutputMessage) ...m.bytes,
    ], allowMalformed: true);
    await until(() => text().contains('karmashala-5d-42'));
    expect(text(), contains('karmashala-5d-42'));
    // The server's own copy of the box's screen says the same.
    expect(
      ssh.remote
          .byId(opened.sessionId.split('/').last)!
          .tailText(20)
          .join('\n'),
      contains('karmashala-5d-42'),
    );
    await client.close();
    await terminals.close(opened.sessionId);
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('the relay on the box starts from the deployed bundle, and is taken '
      'away again', () async {
    final started = (await window.handleLater(
      const SshBoxRelay('live', SshRelayAction.start, port: 18787),
    )).value;
    final reading = started.value;
    expect(reading, isNotNull, reason: started.deployment?.reason);
    expect(
      reading!.status,
      anyOf(SshRelayStatus.running, SshRelayStatus.unreachable),
      reason: reading.reason,
    );
    final removed = (await window.handleLater(
      const SshBoxRelay('live', SshRelayAction.remove, port: 18787),
    )).value;
    expect(removed.value?.status, SshRelayStatus.stopped);
  }, timeout: const Timeout(Duration(minutes: 4)));
}
