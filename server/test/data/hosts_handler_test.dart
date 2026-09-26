import 'dart:convert';

import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/karmashala_environments.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// Where agents run and who they run as, at the server: environments, saved
/// SSH hosts, trusted host keys (the host-key rules), agent installations
/// (the one reconciliation), saved accounts (credentials never told) and the
/// usage history — each rule, and what every other client is told.
void main() {
  late AppDatabase db;
  late DataService service;
  late DataSession app;
  late List<DataChanges> told;
  final now = DateTime.utc(2026, 9, 26, 12);
  final opens = <String>{};

  setUp(() {
    db = AppDatabase.memory();
    opens.clear();
    service = DataService(db, clock: () => now, opens: opens.contains);
    app = service.open((_) {});
    told = [];
    service.open(told.add).handle(const DataSubscribe());
  });
  tearDown(() => db.close());

  Matcher refused(DataRefusalCode code, [String? words]) => throwsA(
    isA<DataRefused>()
        .having((r) => r.code, 'code', code)
        .having((r) => r.message, 'message', contains(words ?? '')),
  );

  List<DataChange> toldChanges() => [for (final b in told) ...b.changes];

  /// What went over the wire to the other client, as text.
  String toldText() => jsonEncode([for (final b in told) b.toJson()]);

  ExecutionEnvironment windows() => ExecutionEnvironment(
    id: 'windows',
    kind: EnvironmentKind.windowsNative,
    name: 'Windows',
    createdAt: now,
  );

  SshHost host({
    String id = 'h1',
    SshAuthMethod auth = SshAuthMethod.privateKey,
    String name = 'build-box',
  }) => SshHost(
    id: id,
    name: name,
    host: 'build.example.com',
    port: 22,
    username: 'dev',
    authMethod: auth,
    privateKey: auth == SshAuthMethod.privateKey
        ? const EnvironmentPath(
            environmentId: 'windows',
            path: r'C:\Users\me\.ssh\id_ed25519',
          )
        : null,
    createdAt: now,
  );

  group('environments', () {
    test('a discovered one is recorded and told; the first time stands', () {
      app.handle(EnvironmentPut(windows()));
      final renamed = app
          .handle(
            EnvironmentPut(
              windows().copyWith(
                name: 'Windows 11',
                createdAt: now.add(const Duration(days: 1)),
              ),
            ),
          )
          .value;
      expect(renamed.name, 'Windows 11');
      expect(renamed.createdAt, now);
      expect(toldChanges().whereType<EnvironmentChanged>(), hasLength(2));
      expect(
        app.handle(const EnvironmentsList()).value.environments.single.name,
        'Windows 11',
      );
    });

    test('one out of shape, or an SSH one, is refused', () {
      expect(
        () => app.handle(
          EnvironmentPut(
            ExecutionEnvironment(
              id: 'wsl:Ubuntu',
              kind: EnvironmentKind.wsl,
              name: 'Ubuntu',
              createdAt: now,
            ),
          ),
        ),
        refused(DataRefusalCode.invalid, 'distribution'),
      );
      expect(
        () => app.handle(EnvironmentPut(sshEnvironment(host()))),
        refused(DataRefusalCode.invalid, 'with its host'),
      );
    });

    test('this machine is ensured once, without overwriting', () {
      service.ensureEnvironment(windows());
      service.ensureEnvironment(windows().copyWith(name: 'Other'));
      final rows = app.handle(const EnvironmentsList()).value.environments;
      expect(rows.single.name, 'Windows');
      expect(toldChanges(), hasLength(1));
    });
  });

  group('SSH hosts', () {
    setUp(() => app.handle(EnvironmentPut(windows())));

    test('saving writes the host and its environment together', () {
      final saved = app.handle(SshHostPut(host())).value;
      expect(saved, host());
      final snapshot = app.handle(const EnvironmentsList()).value;
      expect(snapshot.sshHosts.single, host());
      expect(
        snapshot.environments.map((e) => e.id),
        containsAll(['windows', 'ssh:h1']),
      );
    });

    test('another client is told the host by id — never its key path', () {
      app.handle(SshHostPut(host()));
      expect(toldChanges().whereType<SshHostTouched>().single.id, 'h1');
      expect(toldText(), isNot(contains('id_ed25519')));
      expect(toldText(), isNot(contains('.ssh')));
    });

    test('a host out of shape, or a key on no known machine, is refused', () {
      expect(
        () => app.handle(SshHostPut(host().copyWith(port: 0))),
        refused(DataRefusalCode.invalid, '65535'),
      );
      expect(
        () => app.handle(
          SshHostPut(
            host().copyWith(
              privateKey: const EnvironmentPath(
                environmentId: 'wsl:Nope',
                path: '/k',
              ),
            ),
          ),
        ),
        refused(DataRefusalCode.notFound, 'wsl:Nope'),
      );
    });

    test('a host projects still use is not removed, and says who', () {
      app.handle(SshHostPut(host()));
      app.handle(
        const ProjectCreate(
          projectName: 'Remote',
          root: EnvironmentPath(environmentId: 'ssh:h1', path: '/src'),
        ),
      );
      expect(
        () => app.handle(const SshHostDelete('h1')),
        refused(DataRefusalCode.invalid, 'Remote'),
      );
      expect(app.handle(const EnvironmentsList()).value.sshHosts, hasLength(1));
    });

    test('removing takes the environment and keeps the trusted key', () {
      app.handle(SshHostPut(host()));
      app.handle(
        KnownHostTrust(
          KnownHostKey(
            host: 'build.example.com',
            port: 22,
            keyType: 'ssh-ed25519',
            fingerprint: 'SHA256:abc',
            trustedAt: now,
          ),
        ),
      );
      app.handle(const SshHostDelete('h1'));
      final snapshot = app.handle(const EnvironmentsList()).value;
      expect(snapshot.sshHosts, isEmpty);
      expect(snapshot.environments.map((e) => e.id), ['windows']);
      expect(snapshot.knownHosts, hasLength(1));
      expect(toldChanges().whereType<SshHostRemoved>(), hasLength(1));
      expect(toldChanges().whereType<EnvironmentRemoved>(), hasLength(1));
    });
  });

  group('trusted host keys', () {
    KnownHostKey key([String fingerprint = 'SHA256:abc']) => KnownHostKey(
      host: 'build-box',
      port: 22,
      keyType: 'ssh-ed25519',
      fingerprint: fingerprint,
      trustedAt: DateTime.utc(2000),
    );

    test('a first key is trusted at the server\'s time and told', () {
      final trusted = app.handle(KnownHostTrust(key())).value;
      expect(trusted.trustedAt, now);
      expect(toldChanges().whereType<KnownHostChanged>().single.key, trusted);
    });

    test('the same key again changes nothing', () {
      app.handle(KnownHostTrust(key()));
      told.clear();
      app.handle(KnownHostTrust(key()));
      expect(toldChanges(), isEmpty);
    });

    test('a changed key is refused, and the trusted one stands', () {
      app.handle(KnownHostTrust(key()));
      expect(
        () => app.handle(KnownHostTrust(key('SHA256:intruder'))),
        refused(DataRefusalCode.invalid, 'Forget it first'),
      );
      expect(
        app
            .handle(const EnvironmentsList())
            .value
            .knownHosts
            .single
            .fingerprint,
        'SHA256:abc',
      );
    });

    test('forgetting is the one way to trust a rebuilt host', () {
      app.handle(KnownHostTrust(key()));
      app.handle(const KnownHostForget('build-box', 22));
      expect(toldChanges().whereType<KnownHostRemoved>(), hasLength(1));
      app.handle(KnownHostTrust(key('SHA256:rebuilt')));
      expect(
        app
            .handle(const EnvironmentsList())
            .value
            .knownHosts
            .single
            .fingerprint,
        'SHA256:rebuilt',
      );
    });

    test('a key out of shape is refused', () {
      expect(
        () => app.handle(KnownHostTrust(key('MD5:aa'))),
        refused(DataRefusalCode.invalid, 'SHA256'),
      );
    });
  });

  group('installations', () {
    setUp(() => app.handle(EnvironmentPut(windows())));

    AgentInstallation found(
      String id,
      String path, {
      String agentId = 'codex',
      String? version,
    }) => AgentInstallation(
      id: id,
      agentId: agentId,
      executable: EnvironmentPath(environmentId: 'windows', path: path),
      version: version,
      createdAt: now,
    );

    InstallationsReconciled reconcile(
      List<AgentInstallation> rows, {
      Set<String> probed = const {'codex'},
      Map<String, ExecutableReachability> readings = const {},
    }) => service.reconcileProbe(
      environmentId: 'windows',
      readAt: now,
      found: rows,
      probed: probed,
      readings: readings,
    );

    List<AgentInstallation> rows() =>
        app.handle(const AgentsList()).value.installations;

    test('a new CLI is a row; the same one again records its version', () {
      expect(reconcile([found('a', r'C:\codex.exe')]).added.single.id, 'a');
      final again = reconcile([found('b', r'C:\codex.exe', version: '2.0')]);
      expect(again.added, isEmpty);
      expect(again.versionChanges.single.to, '2.0');
      expect(rows().single.id, 'a');
      expect(rows().single.versionReadAt, now);
      expect(toldChanges().whereType<InstallationChanged>(), hasLength(2));
    });

    test('a pinned path that works is not overruled; one that moved '
        'keeps its id', () {
      reconcile([found('mine', r'C:\mine.exe')]);
      app.handle(const InstallationSetPath(id: 'mine', path: r'C:\pin.exe'));
      final kept = reconcile(
        [found('new', r'C:\found.exe')],
        readings: {'mine': ExecutableReachability.usable},
      );
      expect(kept.pinned.single.id, 'mine');
      expect(rows().single.executable.path, r'C:\pin.exe');

      final moved = reconcile(
        [found('new', r'C:\found.exe')],
        readings: {'mine': ExecutableReachability.missing},
      );
      expect(moved.pathChanges.single.to, r'C:\found.exe');
      expect(rows().single.id, 'mine');
      expect(rows().single.executableByUser, isFalse);
    });

    test('a CLI not found is removed — unless a session points at it', () {
      reconcile([
        found('free', r'C:\free.exe'),
        found('used', r'C:\used.exe', agentId: 'claudeCode'),
      ]);
      app.handle(
        const ProjectCreate(
          projectName: 'P',
          root: EnvironmentPath(environmentId: 'windows', path: r'C:\p'),
        ),
      );
      final checkout = app
          .handle(const WorkspaceList())
          .value
          .repositories
          .single;
      db.execute(
        'INSERT INTO sessions (id, repository_id, agent_installation_id, '
        "title, use_worktree, status, created_at) VALUES ('s', ?, 'used', "
        "'t', 0, 'idle', ?);",
        [checkout.id, now.toIso8601String()],
      );
      final swept = reconcile(const [], probed: {'codex', 'claudeCode'});
      expect(swept.removed.single.id, 'free');
      expect(swept.retained.single.id, 'used');
      expect(rows().single.id, 'used');
      expect(toldChanges().whereType<InstallationRemoved>().single.id, 'free');
    });

    test('an unreachable path is kept: no evidence of absence', () {
      reconcile([found('far', r'C:\far.exe')]);
      final swept = reconcile(
        const [],
        readings: {'far': ExecutableReachability.unreachable},
      );
      expect(swept.unreachable.single.id, 'far');
      expect(rows(), hasLength(1));
    });

    test('a path another row holds, a blank path, an unknown row: refused', () {
      reconcile([
        found('c', r'C:\c.exe', agentId: 'claudeCode'),
        found('d', r'C:\d.exe', agentId: 'claudeCode'),
      ]);
      expect(
        () => app.handle(const InstallationSetPath(id: 'c', path: r'C:\d.exe')),
        refused(DataRefusalCode.invalid),
      );
      expect(
        () => app.handle(const InstallationSetPath(id: 'c', path: ' ')),
        refused(DataRefusalCode.invalid),
      );
      expect(
        () => service.recordInstallationVersion('nope', '1', now),
        refused(DataRefusalCode.notFound),
      );
    });

    test('an environment nobody recorded is refused', () {
      expect(
        () => service.reconcileProbe(
          environmentId: 'wsl:Nope',
          readAt: now,
          found: const [],
          probed: const {},
          readings: const {},
        ),
        refused(DataRefusalCode.notFound, 'wsl:Nope'),
      );
    });

    test('the server\'s own find follows the same rules and is told', () {
      opens.add(r'C:\old.exe');
      reconcile([found('kept', r'C:\old.exe')]);
      opens.clear(); // gone from its old path
      told.clear();
      final written = service.recordAgentsFound(windows(), [
        found('fresh', r'C:\new.exe', version: '3'),
      ], now);
      expect(written.added, isEmpty);
      expect(rows().single.id, 'kept');
      expect(rows().single.executable.path, r'C:\new.exe');
      expect(toldChanges().whereType<InstallationChanged>(), hasLength(1));
    });
  });

  group('saved accounts', () {
    ClaudeAccount claude({String id = 'a1', String token = 'secret-token'}) =>
        ClaudeAccount(
          id: id,
          email: 'me@x.com',
          organizationUuid: 'org',
          claudeAiOauth: {'accessToken': token, 'refreshToken': 'refresh-$id'},
          oauthAccount: const {'accountUuid': 'uuid-1'},
          capturedAt: now,
        );

    CodexAccount codex({String id = 'c1'}) => CodexAccount(
      id: id,
      accountId: 'acct',
      auth: const {'tokens': 'codex-secret'},
      capturedAt: now,
    );

    test('a save answers and tells the account without its credentials', () {
      final saved = service.saveClaudeAccount(claude());
      expect(saved.claudeAiOauth, isEmpty);
      expect(saved.oauthAccount, isNull);
      service.saveCodexAccount(codex());
      expect(toldText(), isNot(contains('secret')));
      expect(toldText(), isNot(contains('refresh-')));
      expect(toldText(), isNot(contains('uuid-1')));
      final listed = app.handle(const AgentsList()).value;
      expect(jsonEncode(listed.toJson()), isNot(contains('secret')));
    });

    test('credentials are the server\'s alone: no request reads them', () {
      service.saveClaudeAccount(claude());
      service.saveCodexAccount(codex());
      told.clear();
      final full = service.claudeAccount('a1');
      expect(full.claudeAiOauth['accessToken'], 'secret-token');
      expect(full.oauthAccount, {'accountUuid': 'uuid-1'});
      expect(service.codexAccount('c1').auth, {'tokens': 'codex-secret'});
      expect(told, isEmpty, reason: 'a read is never told');
      for (final kind in [
        'claudeAccounts.credentials',
        'codexAccounts.credentials',
        'claudeAccounts.save',
        'codexAccounts.save',
      ]) {
        final answer = app.handleJson({
          'id': 9,
          'kind': kind,
          'arguments': {'id': 'a1'},
        });
        expect(jsonEncode(answer), isNot(contains('secret')), reason: kind);
        expect(jsonEncode(answer), contains('refusal'), reason: kind);
      }
    });

    test('a re-capture of the same account keeps its id', () {
      service.saveClaudeAccount(claude());
      final again = service.saveClaudeAccount(claude(id: 'a2', token: 'newer'));
      expect(again.id, 'a1');
      expect(
        service.claudeAccount('a1').claudeAiOauth,
        containsPair('accessToken', 'newer'),
      );
    });

    test('an account without credentials is refused; forgetting is told', () {
      expect(
        () => service.saveClaudeAccount(
          claudeAccountWithoutCredentials(claude()),
        ),
        refused(DataRefusalCode.invalid, 'sign-in'),
      );
      service.saveClaudeAccount(claude());
      app.handle(const ClaudeAccountDelete('a1'));
      expect(toldChanges().whereType<ClaudeAccountRemoved>(), hasLength(1));
      expect(
        () => service.claudeAccount('a1'),
        refused(DataRefusalCode.notFound),
      );
    });

    test('a store failure never quotes the values it was given', () {
      db.execute('DROP TABLE claude_accounts;');
      Object? error;
      try {
        service.saveClaudeAccount(claude());
      } on Object catch (e) {
        error = e;
      }
      expect(error, isA<DataRefused>());
      expect('$error', contains('failed'));
      expect('$error', isNot(contains('secret')));
    });
  });

  group('usage history', () {
    const account = 'claudeCode@windows';
    UsageSample sample(DateTime at, double percent, {String window = '5-h'}) =>
        UsageSample(
          accountKey: account,
          windowLabel: window,
          percent: percent,
          recordedAt: at,
        );

    int record(List<UsageSample> samples) => service.recordUsage(samples);

    List<UsageSample> history() =>
        app.handle(UsageHistory(account, DateTime.utc(2000))).value;

    test('repeats are skipped until the heartbeat; changes are kept', () {
      expect(record([sample(now, 20), sample(now, 5, window: '7-d')]), 2);
      expect(record([sample(now.add(const Duration(minutes: 3)), 20)]), 0);
      expect(record([sample(now.add(const Duration(minutes: 4)), 24)]), 1);
      expect(record([sample(now.add(kUsageHistoryHeartbeat * 2), 24)]), 1);
      expect(history(), hasLength(4));
      expect(toldChanges().whereType<UsageRecorded>(), hasLength(3));
    });

    test('pruned by the readings\' clock, at most once an hour', () {
      db.execute(
        'INSERT INTO usage_samples (account_key, window_label, percent, '
        'recorded_at) VALUES (?, ?, ?, ?);',
        [
          account,
          'ancient',
          1,
          now.subtract(const Duration(days: 40)).toIso8601String(),
        ],
      );
      record([sample(now, 20)]);
      expect(history().where((s) => s.windowLabel == 'ancient'), isEmpty);
      db.execute(
        'INSERT INTO usage_samples (account_key, window_label, percent, '
        'recorded_at) VALUES (?, ?, ?, ?);',
        [
          account,
          'ancient',
          1,
          now.subtract(const Duration(days: 40)).toIso8601String(),
        ],
      );
      record([sample(now.add(const Duration(minutes: 10)), 22)]);
      expect(history().where((s) => s.windowLabel == 'ancient'), hasLength(1));
      record([sample(now.add(const Duration(minutes: 61)), 23)]);
      expect(history().where((s) => s.windowLabel == 'ancient'), isEmpty);
    });
  });
}
