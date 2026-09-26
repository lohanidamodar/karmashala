import 'dart:convert';

import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/karmashala_environments.dart';
import 'package:test/test.dart';

/// Environments, SSH hosts, trusted keys, installations, saved accounts and
/// usage through the envelope as JSON text — and the credentials and key
/// locations that must not ride along.
void main() {
  final t0 = DateTime.utc(2026, 9, 26, 9, 30);
  final environment = ExecutionEnvironment(
    id: 'wsl:Ubuntu',
    kind: EnvironmentKind.wsl,
    name: 'Ubuntu',
    wslDistribution: 'Ubuntu',
    createdAt: t0,
  );
  final host = SshHost(
    id: 'h1',
    name: 'box',
    host: 'box.example.com',
    port: 2222,
    username: 'dev',
    authMethod: SshAuthMethod.privateKey,
    privateKey: const EnvironmentPath(
      environmentId: 'windows',
      path: r'C:\Users\me\.ssh\id_ed25519',
    ),
    defaultDirectory: const EnvironmentPath(
      environmentId: 'ssh:h1',
      path: '/src',
    ),
    createdAt: t0,
  );
  final key = KnownHostKey(
    host: 'box',
    port: 22,
    keyType: 'ssh-ed25519',
    fingerprint: 'SHA256:abc',
    trustedAt: t0,
  );
  final installation = AgentInstallation(
    id: 'a1',
    agentId: 'codex',
    executable: const EnvironmentPath(environmentId: 'windows', path: 'c.exe'),
    version: '1.2',
    versionReadAt: t0,
    executableByUser: true,
    createdAt: t0,
  );
  final claude = ClaudeAccount(
    id: 'c',
    email: 'me@x.com',
    organizationUuid: 'org',
    claudeAiOauth: const {'accessToken': 'secret-token'},
    oauthAccount: const {'accountUuid': 'uuid'},
    capturedAt: t0,
  );
  final codex = CodexAccount(
    id: 'x',
    accountId: 'acct',
    email: 'me@x.com',
    auth: const {'tokens': 'secret-token'},
    capturedAt: t0,
  );
  final sample = UsageSample(
    accountKey: 'k',
    windowLabel: '5-hour',
    percent: 12.5,
    span: const Duration(hours: 5),
    resetsAt: t0,
    recordedAt: t0,
  );

  Map<String, Object?> overTheWire(Map<String, Object?> json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  test('every request round-trips with its arguments', () {
    final requests = <DataRequest<Object?>>[
      const EnvironmentsList(),
      EnvironmentPut(environment),
      SshHostPut(host),
      const SshHostDelete('h1'),
      KnownHostTrust(key),
      const KnownHostForget('box', 22),
      const AgentsList(),
      InstallationsReconcile(
        environmentId: 'windows',
        readAt: t0,
        found: [installation],
        probed: const {'codex'},
        readings: const {'a1': ExecutableReachability.unreachable},
      ),
      InstallationVersion(id: 'a1', version: '2', readAt: t0),
      const InstallationSetPath(id: 'a1', path: 'd.exe'),
      ClaudeAccountSave(claude),
      const ClaudeAccountCredentials('c'),
      const ClaudeAccountDelete('c'),
      CodexAccountSave(codex),
      const CodexAccountCredentials('x'),
      const CodexAccountDelete('x'),
      UsageRecord([sample]),
      UsageHistory('k', t0),
    ];
    for (final request in requests) {
      final read = DataEnvelope.readRequest(
        overTheWire(DataEnvelope.request(3, request)),
      );
      expect(read.refusal, isNull, reason: request.kind);
      expect(read.request!.kind, request.kind);
      expect(
        read.request!.argumentsToJson(),
        request.argumentsToJson(),
        reason: request.kind,
      );
    }
  });

  test('a save carries the credentials it saves; its toString does not', () {
    final json = jsonEncode(DataEnvelope.request(1, ClaudeAccountSave(claude)));
    expect(json, contains('secret-token'));
    expect('${ClaudeAccountSave(claude)}', isNot(contains('secret')));
    final read =
        DataEnvelope.readRequest(
              overTheWire(jsonDecode(json) as Map<String, Object?>),
            ).request!
            as ClaudeAccountSave;
    expect(read.account.claudeAiOauth, claude.claudeAiOauth);
  });

  test('answers carry typed results', () {
    DataReply<R> roundTrip<R>(DataRequest<R> request, R result) =>
        DataEnvelope.readAnswer(
          overTheWire(
            DataEnvelope.answer(4, request, DataReply(result, 9, const [])),
          ),
          request,
        );

    final hosts = roundTrip(
      const EnvironmentsList(),
      EnvironmentsSnapshot(
        environments: [environment],
        sshHosts: [host],
        knownHosts: [key],
      ),
    ).value;
    expect(hosts.environments, [environment]);
    expect(hosts.sshHosts, [host], reason: 'the asker gets the key location');
    expect(hosts.knownHosts, [key]);

    final agents = roundTrip(
      const AgentsList(),
      AgentsSnapshot(
        installations: [installation],
        claudeAccounts: [claude],
        codexAccounts: [codex],
      ),
    ).value;
    expect(agents.installations, [installation]);
    expect(agents.claudeAccounts.single.claudeAiOauth, isEmpty);
    expect(agents.codexAccounts.single.auth, isEmpty);

    expect(
      roundTrip(
        const ClaudeAccountCredentials('c'),
        claude,
      ).value.claudeAiOauth['accessToken'],
      'secret-token',
    );
    expect(
      roundTrip(const CodexAccountCredentials('x'), codex).value.auth,
      codex.auth,
    );
    expect(roundTrip(UsageRecord([sample]), 1).value, 1);
    expect(roundTrip(UsageHistory('k', t0), [sample]).value, [sample]);
    expect(
      roundTrip(
        const InstallationSetPath(id: 'a1', path: 'd'),
        installation,
      ).value,
      installation,
    );
  });

  test('every change round-trips; none carries a credential or key path', () {
    final changes = <DataChange>[
      EnvironmentChanged(environment),
      const EnvironmentRemoved('e'),
      const SshHostTouched('h1'),
      const SshHostRemoved('h1'),
      KnownHostChanged(key),
      const KnownHostRemoved('box', 22),
      InstallationChanged(installation),
      const InstallationRemoved('a1'),
      ClaudeAccountChanged(claude),
      const ClaudeAccountRemoved('c'),
      CodexAccountChanged(codex),
      const CodexAccountRemoved('x'),
      const UsageRecorded('k'),
    ];
    final wire = jsonEncode(DataChanges(5, changes).toJson());
    expect(wire, isNot(contains('secret')));
    expect(wire, isNot(contains('id_ed25519')));
    expect(wire, isNot(contains('uuid')));
    final back = DataChanges.fromJson(
      (jsonDecode(wire) as Map).cast<String, Object?>(),
    );
    expect(back.changes.map((c) => c.runtimeType), [
      for (final c in changes) c.runtimeType,
    ]);
    expect((back.changes[0] as EnvironmentChanged).environment, environment);
    expect((back.changes[4] as KnownHostChanged).key, key);
    expect((back.changes[6] as InstallationChanged).installation, installation);
    expect((back.changes[5] as KnownHostRemoved).port, 22);
  });

  test('a misshapen reconcile is refused, not thrown', () {
    final read = DataEnvelope.readRequest({
      'id': 1,
      'kind': 'installations.reconcile',
      'arguments': {
        'environmentId': 'windows',
        'readAt': t0.toIso8601String(),
        'readings': {'a1': 'sideways'},
      },
    });
    expect(read.request, isNull);
    expect(read.refusal!.code, DataRefusalCode.invalid);
  });
}
