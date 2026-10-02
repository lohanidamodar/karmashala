import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala_environments/karmashala_environments.dart';
import 'package:karmashala_environments/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// The tables behind environments, SSH hosts, trusted keys, installations,
/// saved accounts and the usage history — the server's DAOs (moved from the
/// app in slice 1d).
void main() {
  final t0 = DateTime.utc(2026, 9, 26, 12);
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  ExecutionEnvironment windows() => ExecutionEnvironment(
    id: 'windows',
    kind: EnvironmentKind.windowsNative,
    name: 'Windows',
    createdAt: t0,
  );

  ExecutionEnvironment wsl() => ExecutionEnvironment(
    id: 'wsl:Ubuntu',
    kind: EnvironmentKind.wsl,
    name: 'Ubuntu',
    wslDistribution: 'Ubuntu',
    createdAt: t0,
  );

  group('environments', () {
    late ExecutionEnvironmentDao dao;
    setUp(() => dao = ExecutionEnvironmentDao(db));

    test('round-trips, upserts in place, deletes', () {
      dao.upsert(windows());
      dao.upsert(wsl());
      expect(dao.getById('windows'), windows());
      expect(dao.getById('wsl:Ubuntu')!.wslDistribution, 'Ubuntu');
      dao.upsert(windows().copyWith(name: 'Windows 11'));
      expect(dao.getAll(), hasLength(2));
      expect(dao.getById('windows')!.name, 'Windows 11');
      expect(dao.getById('nope'), isNull);
      dao.delete('windows');
      expect(dao.getById('windows'), isNull);
    });

    test('ensure keeps the row already recorded', () {
      expect(dao.ensure(windows()), isTrue);
      expect(dao.ensure(windows().copyWith(name: 'Other')), isFalse);
      expect(dao.getById('windows')!.name, 'Windows');
    });
  });

  group('agent installations', () {
    late AgentInstallationDao dao;

    AgentInstallation installation({
      String id = 'a1',
      String agentId = AgentIds.claudeCode,
      String environmentId = 'windows',
      String path = r'C:\Users\me\.bin\claude.exe',
      String? version = '1.0.0',
    }) => AgentInstallation(
      id: id,
      agentId: agentId,
      executable: EnvironmentPath(environmentId: environmentId, path: path),
      version: version,
      createdAt: t0,
    );

    setUp(() {
      ExecutionEnvironmentDao(db)
        ..upsert(windows())
        ..upsert(wsl());
      dao = AgentInstallationDao(db);
    });

    test('round-trips; Windows and WSL are independent rows', () {
      dao.insert(installation(id: 'win'));
      dao.insert(
        installation(
          id: 'wsl',
          environmentId: 'wsl:Ubuntu',
          path: '/home/me/.local/bin/claude',
          version: null,
        ),
      );
      expect(dao.getById('win'), installation(id: 'win'));
      expect(dao.getById('wsl')!.version, isNull);
      expect(dao.getByEnvironment('windows').single.id, 'win');
      expect(dao.getByEnvironment('wsl:Ubuntu').single.id, 'wsl');
      expect(
        dao
            .getByIdentity(
              AgentIds.claudeCode,
              'windows',
              r'C:\Users\me\.bin\claude.exe',
            )!
            .id,
        'win',
      );
    });

    test('finds every installation of one agent, on every machine', () {
      dao.insert(installation(id: 'win', agentId: 'acp:r1'));
      dao.insert(
        installation(
          id: 'wsl',
          agentId: 'acp:r1',
          environmentId: 'wsl:Ubuntu',
          path: '/usr/bin/mine',
        ),
      );
      dao.insert(installation(id: 'other'));
      expect(dao.getByAgent('acp:r1').map((i) => i.id), ['win', 'wsl']);
      expect(dao.getByAgent('acp:r2'), isEmpty);
    });

    test('the same (agent, environment, executable) twice is refused', () {
      dao.insert(installation(id: 'a1'));
      expect(
        () => dao.insert(installation(id: 'a2')),
        throwsA(isA<SqliteException>()),
      );
    });

    test('a row written before v39 reads as detected, not hand-set', () {
      db.execute(
        'INSERT INTO agent_installations '
        '(id, agent_kind, environment_id, executable_path, version, '
        'created_at) VALUES (?, ?, ?, ?, ?, ?);',
        ['legacy', 'claudeCode', 'windows', r'C:\old\c.exe', '1', '$t0'],
      );
      final legacy = dao.getById('legacy')!;
      expect(legacy.agentId, AgentIds.claudeCode);
      expect(legacy.executableByUser, isFalse);
    });

    test('moving keeps the id, records who chose, refuses a taken path', () {
      dao.insert(installation(id: 'a1', path: r'C:\one\c.exe'));
      dao.insert(installation(id: 'a2', path: r'C:\two\c.exe'));
      expect(dao.updatePath('a1', r'C:\real\c.exe', byUser: true), isTrue);
      expect(dao.getById('a1')!.executable.path, r'C:\real\c.exe');
      expect(dao.getById('a1')!.executableByUser, isTrue);
      expect(dao.updatePath('a2', r'C:\real\c.exe', byUser: true), isFalse);
      expect(dao.getById('a2')!.executable.path, r'C:\two\c.exe');
    });

    test('a null version reading is never written', () {
      dao.insert(installation());
      dao.recordVersion('a1', null, readAt: t0);
      expect(dao.getById('a1')!.version, '1.0.0');
      dao.recordVersion('a1', '2.0.0', readAt: t0);
      expect(dao.getById('a1')!.versionReadAt, t0);
    });

    test(
      'one a session points at is kept, and says so rather than raising',
      () {
        dao.insert(installation());
        db.execute(
          "INSERT INTO projects (id, name, root_environment_id, root_path, "
          "created_at) VALUES ('p', 'P', 'windows', 'C:\\p', '$t0');",
        );
        db.execute(
          "INSERT INTO repositories (id, project_id, name, environment_id, "
          "path, created_at) VALUES ('r', 'p', 'r', 'windows', 'C:\\p', "
          "'$t0');",
        );
        db.execute(
          "INSERT INTO sessions (id, repository_id, agent_installation_id, "
          "title, use_worktree, status, created_at) VALUES ('s', 'r', 'a1', "
          "'t', 0, 'idle', '$t0');",
        );
        expect(dao.deleteIfUnreferenced('a1'), isFalse);
        expect(dao.getById('a1'), isNotNull);
        dao.insert(installation(id: 'free', path: r'C:\free\c.exe'));
        expect(dao.deleteIfUnreferenced('free'), isTrue);
      },
    );
  });

  group('SSH hosts', () {
    late SshHostDao dao;

    SshHost host({
      String name = 'build-box',
      SshAuthMethod auth = SshAuthMethod.privateKey,
      String? directory,
    }) => SshHost(
      id: 'h1',
      name: name,
      host: 'build.example.com',
      port: 2222,
      username: 'dev',
      authMethod: auth,
      privateKey: auth == SshAuthMethod.privateKey
          ? const EnvironmentPath(
              environmentId: 'windows',
              path: r'C:\Users\me\.ssh\id_ed25519',
            )
          : null,
      defaultDirectory: directory == null
          ? null
          : EnvironmentPath(environmentId: 'ssh:h1', path: directory),
      createdAt: t0,
    );

    setUp(() => dao = SshHostDao(db));

    test('round-trips a key host; the key path keeps its environment', () {
      dao.upsert(host(directory: '/home/dev/src'));
      final loaded = dao.getById('h1')!;
      expect(loaded, host(directory: '/home/dev/src'));
      expect(loaded.privateKey!.environmentId, 'windows');
      expect(loaded.defaultDirectory!.environmentId, 'ssh:h1');
    });

    test('a password host stores no key; the table has no credential', () {
      dao.upsert(host(auth: SshAuthMethod.password));
      expect(dao.getById('h1')!.privateKey, isNull);
      final columns = [
        for (final row in db.query('PRAGMA table_info(ssh_hosts);'))
          (row['name']! as String).toLowerCase(),
      ];
      for (final forbidden in ['password', 'passphrase', 'secret']) {
        expect(columns, isNot(contains(forbidden)));
      }
      expect(columns, isNot(contains('private_key')));
      expect(columns, contains('private_key_path'));
    });

    test('upserts in place and deletes; toString never shows the key', () {
      dao.upsert(host());
      dao.upsert(host(name: 'renamed'));
      expect(dao.getAll().single.name, 'renamed');
      expect(host().toString(), isNot(contains('id_ed25519')));
      dao.delete('h1');
      expect(dao.getAll(), isEmpty);
    });
  });

  group('trusted host keys', () {
    late KnownHostDao dao;
    KnownHostKey key({int port = 22, String fingerprint = 'SHA256:abc'}) =>
        KnownHostKey(
          host: 'build-box',
          port: port,
          keyType: 'ssh-ed25519',
          fingerprint: fingerprint,
          trustedAt: t0,
        );

    setUp(() => dao = KnownHostDao(db));

    test('one key per address; forget removes only that address', () {
      dao.trust(key());
      dao.trust(key(port: 2222));
      expect(dao.find('build-box', 22), key());
      expect(dao.find('other', 22), isNull);
      dao.trust(key(fingerprint: 'SHA256:xyz'));
      expect(dao.getAll(), hasLength(2));
      expect(dao.find('build-box', 22)!.fingerprint, 'SHA256:xyz');
      dao.forget('build-box', 22);
      expect(dao.find('build-box', 22), isNull);
      expect(dao.find('build-box', 2222), isNotNull);
    });
  });

  group('saved accounts', () {
    ClaudeAccount claude({String id = 'a1', String? org = 'org-1'}) =>
        ClaudeAccount(
          id: id,
          email: 'me@x.com',
          organizationUuid: org,
          organizationName: 'Org',
          claudeAiOauth: {'accessToken': 'tok-$id', 'expiresAt': 123},
          oauthAccount: {'emailAddress': 'me@x.com'},
          capturedEnvironmentId: 'wsl:archlinux',
          capturedAt: t0,
        );

    test('a Claude account is one row per (email, organization)', () {
      final dao = ClaudeAccountDao(db);
      dao.upsert(claude());
      expect(dao.upsert(claude(id: 'a2')).id, 'a1');
      expect(dao.getAll().single.claudeAiOauth['accessToken'], 'tok-a2');
      dao.upsert(claude(id: 'n1', org: null));
      expect(dao.upsert(claude(id: 'n2', org: null)).id, 'n1');
      dao.upsert(claude(id: 'o2', org: 'org-2'));
      expect(dao.getAll(), hasLength(3));
      dao.delete('a1');
      expect(dao.getById('a1'), isNull);
    });

    test('a Codex account is one row per account id', () {
      final dao = CodexAccountDao(db);
      CodexAccount codex(String id, String email) => CodexAccount(
        id: id,
        accountId: 'acct',
        email: email,
        auth: {'tokens': 'secret-$id'},
        capturedAt: t0,
      );
      dao.upsert(codex('c1', 'first@x.com'));
      expect(dao.upsert(codex('c2', 'second@x.com')).id, 'c1');
      expect(dao.getAll().single.email, 'second@x.com');
      dao.delete('c1');
      expect(dao.getAll(), isEmpty);
    });
  });

  group('usage samples', () {
    late UsageSampleDao dao;
    const account = 'claudeCode@windows';
    setUp(() => dao = UsageSampleDao(db));

    void seed(DateTime at, double percent, {String window = '5-hour'}) =>
        dao.insert(
          UsageSample(
            accountKey: account,
            windowLabel: window,
            percent: percent,
            recordedAt: at,
          ),
        );

    test('forgets anything older than thirty days', () {
      seed(t0.subtract(const Duration(days: 31)), 10);
      seed(t0.subtract(const Duration(days: 29)), 20);
      dao.prune(
        now: t0,
        keep: kUsageHistoryKeep,
        fullResolution: kUsageHistoryFullResolution,
      );
      expect(dao.since(account, DateTime.utc(2000)).map((s) => s.percent), [
        20,
      ]);
    });

    test('thins history older than 48 hours to the peak of each hour', () {
      final old = DateTime.utc(2026, 9, 20, 8);
      seed(old.add(const Duration(minutes: 5)), 10);
      seed(old.add(const Duration(minutes: 25)), 40);
      seed(old.add(const Duration(minutes: 50)), 30);
      seed(old.add(const Duration(minutes: 70)), 50);
      seed(old.add(const Duration(minutes: 10)), 2, window: '7-day');
      seed(old.add(const Duration(minutes: 40)), 3, window: '7-day');
      final recent = t0.subtract(const Duration(hours: 1));
      seed(recent, 60);
      seed(recent.add(const Duration(minutes: 3)), 61);
      dao.prune(
        now: t0,
        keep: kUsageHistoryKeep,
        fullResolution: kUsageHistoryFullResolution,
      );
      final all = dao.since(account, DateTime.utc(2000));
      expect(
        [
          for (final s in all)
            if (s.windowLabel == '5-hour') (s.recordedAt, s.percent),
        ],
        [
          (old.add(const Duration(minutes: 25)), 40.0),
          (old.add(const Duration(minutes: 70)), 50.0),
          (recent, 60.0),
          (recent.add(const Duration(minutes: 3)), 61.0),
        ],
      );
      expect(
        [
          for (final s in all)
            if (s.windowLabel == '7-day') s.percent,
        ],
        [3.0],
      );
      expect(dao.count(), 5);
    });
  });
}
