@Tags(['live'])
library;

import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/ssh.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/src/agents/server_agent_work.dart';
import 'package:karmashala_host/src/ssh/server_ssh.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// The server's own SSH (slice 3a) against a **real** SSH server: a person
/// is asked through a desktop client to trust the key, the trust is
/// recorded, a command runs and the agents there are found — with no app.
///
/// Opt-in, like `karmashala_ssh`'s live suite: set `KARMASHALA_SSH_HOST`,
/// `KARMASHALA_SSH_USER`, `KARMASHALA_SSH_KEY` (a private key path on this
/// machine) and, when it is not 22, `KARMASHALA_SSH_PORT`. The store is in
/// memory: nothing here reads or writes a real data folder.
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
      'live server SSH tests are skipped',
      () {},
      skip:
          'Set KARMASHALA_SSH_HOST, KARMASHALA_SSH_USER and '
          'KARMASHALA_SSH_KEY to run the server\'s live SSH suite.',
    );
    return;
  }

  final now = DateTime.now().toUtc();
  late AppDatabase db;
  late DataService data;
  late ServerSsh ssh;
  late List<DataChange> told;
  late DataSession window;

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

  setUp(() {
    db = AppDatabase.memory();
    data = DataService(db)..ensureEnvironment(localHostEnvironment(now));
    ssh = ServerSsh(data: data, database: db)..attach();
    told = [];
    // A desktop window: it is told the question and answers it.
    window = data.open((batch) {
      told.addAll(batch.changes);
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

  test('a first connection asks a window, pins the key, then '
      'connects', () async {
    final result = (await window.handleLater(
      const SshTest(hostId: 'live'),
    )).value;
    expect(result.connected, isTrue, reason: result.message);
    expect(told.whereType<SshPromptOpened>(), hasLength(1));
    expect(told.whereType<KnownHostChanged>(), hasLength(1));

    told.clear();
    final again = (await window.handleLater(
      const SshTest(hostId: 'live'),
    )).value;
    expect(again.connected, isTrue);
    expect(told.whereType<SshPromptOpened>(), isEmpty);
  });

  test('a command runs on the box over the pooled connection', () async {
    final runner = ssh.runners.forEnvironment(
      data.environments.firstWhere((e) => e.id == host.environmentId),
    );
    final result = await runner.run(
      const CommandRequest(executable: 'uname', arguments: ['-s']),
    );
    expect(result.exitCode, 0);
    expect(result.stdout.trim(), isNotEmpty);
    expect(
      told.whereType<SshConnectionChanged>().last.state.status,
      SshConnectionStatus.connected,
    );
  });

  test('the agents on the box are found by the server', () async {
    final work = ServerAgentWork(
      data: data,
      runners: ssh.runners,
      onItsOwn: false,
    )..attach();
    addTearDown(work.stop);
    final report = (await window.handleLater(
      AgentsDetect(environmentId: host.environmentId),
    )).value;
    final scan = report.environments.single;
    expect(scan.reachable, isTrue, reason: scan.error);
    expect(
      data.installations
          .where((i) => i.environmentId == host.environmentId)
          .map((i) => i.agentId),
      contains(AgentIds.claudeCode),
      reason: 'this suite expects Claude Code installed on the remote host',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
