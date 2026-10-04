import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala_environments/karmashala_environments.dart';
import 'package:test/test.dart';

/// The rules every copy of this domain follows: what a row must be, the one
/// reconciliation of a probe with the recorded installations, what the usage
/// history keeps, and which fields never travel.
void main() {
  final t0 = DateTime.utc(2026, 9, 26, 12);

  group('environments', () {
    ExecutionEnvironment env(
      String id,
      EnvironmentKind kind, {
      String? distribution,
    }) => ExecutionEnvironment(
      id: id,
      kind: kind,
      name: 'Name',
      wslDistribution: distribution,
      createdAt: t0,
    );

    test('this machine is "windows" whatever it runs', () {
      expect(
        environmentProblem(env('windows', EnvironmentKind.localPosix)),
        isNull,
      );
      expect(
        environmentProblem(env('mac', EnvironmentKind.localPosix)),
        contains('"windows"'),
      );
    });

    test('a WSL distribution is wsl:<name>, and names it', () {
      expect(
        environmentProblem(
          env('wsl:Ubuntu', EnvironmentKind.wsl, distribution: 'Ubuntu'),
        ),
        isNull,
      );
      expect(
        environmentProblem(env('wsl:Ubuntu', EnvironmentKind.wsl)),
        isNotNull,
      );
      expect(
        environmentProblem(
          env('wsl:Other', EnvironmentKind.wsl, distribution: 'Ubuntu'),
        ),
        isNotNull,
      );
    });

    test('an SSH environment is only ever its host\'s', () {
      expect(
        environmentProblem(env('ssh:h1', EnvironmentKind.ssh)),
        contains('with its host'),
      );
    });
  });

  group('SSH hosts', () {
    SshHost host({
      String address = 'build.example.com',
      int port = 22,
      String user = 'dev',
      SshAuthMethod auth = SshAuthMethod.privateKey,
      EnvironmentPath? key = const EnvironmentPath(
        environmentId: 'windows',
        path: r'C:\Users\me\.ssh\id_ed25519',
      ),
      EnvironmentPath? directory,
    }) => SshHost(
      id: 'h1',
      name: 'build-box',
      host: address,
      port: port,
      username: user,
      authMethod: auth,
      privateKey: key,
      defaultDirectory: directory,
      createdAt: t0,
    );

    test('a well-formed host passes', () {
      expect(sshHostProblem(host()), isNull);
      expect(
        sshHostProblem(host(auth: SshAuthMethod.password, key: null)),
        isNull,
      );
    });

    test('address, port and user are checked', () {
      expect(sshHostProblem(host(address: ' ')), isNotNull);
      expect(sshHostProblem(host(address: 'a b')), isNotNull);
      expect(sshHostProblem(host(port: 0)), contains('65535'));
      expect(sshHostProblem(host(port: 70000)), contains('65535'));
      expect(sshHostProblem(host(user: '')), isNotNull);
    });

    test('key auth names a key on a machine of this client\'s own', () {
      expect(sshHostProblem(host(key: null)), contains('location'));
      expect(
        sshHostProblem(
          host(
            key: const EnvironmentPath(environmentId: 'ssh:h2', path: '/k'),
          ),
        ),
        contains('not from another SSH host'),
      );
      expect(
        sshHostProblem(host(auth: SshAuthMethod.password)),
        contains('no key location'),
      );
    });

    test('the starting directory is on the host itself', () {
      expect(
        sshHostProblem(
          host(
            directory: const EnvironmentPath(
              environmentId: 'ssh:h1',
              path: '/',
            ),
          ),
        ),
        isNull,
      );
      expect(
        sshHostProblem(
          host(
            directory: const EnvironmentPath(
              environmentId: 'windows',
              path: 'C:',
            ),
          ),
        ),
        isNotNull,
      );
    });

    test('a change never carries where the key is', () {
      final json = sshHostToJson(host(), withKeyPath: false);
      expect(json.containsKey('privateKey'), isFalse);
      expect('$json', isNot(contains('id_ed25519')));
      expect(sshHostFromJson(sshHostToJson(host())), host());
    });
  });

  group('trusted host keys', () {
    KnownHostKey key([String fingerprint = 'SHA256:abc']) => KnownHostKey(
      host: 'build-box',
      port: 22,
      keyType: 'ssh-ed25519',
      fingerprint: fingerprint,
      trustedAt: t0,
    );

    test('a key is recorded by its SHA256 fingerprint', () {
      expect(knownHostProblem(key()), isNull);
      expect(knownHostProblem(key('MD5:aa')), isNotNull);
      expect(knownHostProblem(key('SHA256:')), isNotNull);
    });

    test('a first key and the same key again are trusted', () {
      expect(trustProblem(null, key()), isNull);
      expect(trustProblem(key(), key()), isNull);
    });

    test('a different key for an address already trusted is refused', () {
      expect(
        trustProblem(key(), key('SHA256:changed')),
        allOf(contains('SHA256:abc'), contains('Forget it first')),
      );
    });
  });

  group('reconciling a probe', () {
    AgentInstallation row(
      String id,
      String path, {
      String agentId = 'codex',
      bool byUser = false,
      String? version,
    }) => AgentInstallation(
      id: id,
      agentId: agentId,
      executable: EnvironmentPath(environmentId: 'windows', path: path),
      version: version,
      executableByUser: byUser,
      createdAt: t0,
    );

    InstallationPlan plan(
      List<AgentInstallation> stored,
      List<AgentInstallation> found, {
      Set<String> probed = const {'codex'},
      Map<String, ExecutableReachability> readings = const {},
    }) => planReconcile(
      environmentId: 'windows',
      stored: stored,
      found: found,
      probed: probed,
      readings: readings,
      readAt: t0,
    );

    test('the same path is the same row, its version read now', () {
      final p = plan(
        [row('a', r'C:\c.exe', version: '1')],
        [row('new', r'C:\c.exe', version: '2')],
      );
      expect(p.inserts, isEmpty);
      expect(p.versions, {'a': '2'});
      expect(p.versionChanges.single.to, '2');
      expect(p.present.single.versionReadAt, t0);
    });

    test('the same path with other runner arguments takes them; a new row '
        'carries its own', () {
      const npx = r'C:\npm\npx.cmd';
      final p = plan(
        [row('a', npx), row('b', r'C:\c.exe')],
        [
          row('new', npx).copyWith(leadingArguments: ['-y', 'pkg']),
          row('same', r'C:\c.exe'),
          row(
            'fresh',
            r'C:\other\npx.cmd',
            agentId: 'other',
          ).copyWith(leadingArguments: ['-y', 'other-pkg']),
        ],
      );
      expect(p.leadingArguments, {
        'a': ['-y', 'pkg'],
      });
      expect(p.present.firstWhere((r) => r.id == 'a').leadingArguments, [
        '-y',
        'pkg',
      ]);
      expect(
        p.present.firstWhere((r) => r.id == 'b').leadingArguments,
        isEmpty,
      );
      expect(p.inserts.single.leadingArguments, ['-y', 'other-pkg']);
    });

    test('a row found through npx, whose agent now runs its own binary, '
        'moves to the binary and drops the npx arguments', () {
      final p = plan(
        [
          row('stale', r'C:\npm\npx.cmd', agentId: 'codex-acp').copyWith(
            leadingArguments: ['-y', '@agentclientprotocol/codex-acp'],
          ),
        ],
        [row('new', r'C:\codex\codex.exe', agentId: 'codex-acp')],
        probed: const {'codex-acp'},
      );
      expect(p.inserts, isEmpty);
      expect(p.moves, {'stale': r'C:\codex\codex.exe'});
      expect(p.leadingArguments, {'stale': <String>[]});
      expect(p.present.single.leadingArguments, isEmpty);
    });

    test('a pinned path that is not observed broken is not overruled', () {
      final p = plan(
        [row('mine', r'C:\mine.exe', byUser: true)],
        [row('new', r'C:\found.exe')],
        readings: {'mine': ExecutableReachability.usable},
      );
      expect(p.inserts, isEmpty);
      expect(p.moves, isEmpty);
      expect(p.pinned.single.id, 'mine');
    });

    test('a pinned path observed broken is repaired like any other', () {
      final p = plan(
        [row('mine', r'C:\gone.exe', byUser: true)],
        [row('new', r'C:\found.exe')],
        readings: {'mine': ExecutableReachability.missing},
      );
      expect(p.moves, {'mine': r'C:\found.exe'});
      expect(p.present.single.executableByUser, isFalse);
    });

    test('an agent found elsewhere is the row that moved, keeping its id', () {
      final p = plan([row('kept', r'C:\old.exe')], [row('new', r'C:\new.exe')]);
      expect(p.moves, {'kept': r'C:\new.exe'});
      expect(p.inserts, isEmpty);
      expect(p.pathChanges.single.from, r'C:\old.exe');
      expect(p.present.single.id, 'kept');
    });

    test('a new agent is a new row; a second find of it is the same row', () {
      final p = plan(const [], [
        row('n1', r'C:\c.exe', version: '1'),
        row('n2', r'C:\c.exe', version: '1'),
      ]);
      expect(p.inserts.single.id, 'n1');
      expect(p.present, hasLength(1));
    });

    test('leftovers: unprobed kept, unreachable kept, the rest absent', () {
      final p = plan(
        [
          row('other', r'C:\claude.exe', agentId: 'claude'),
          row('far', r'C:\far.exe'),
          row('gone', r'C:\gone.exe', agentId: 'codex2'),
        ],
        const [],
        probed: {'codex', 'codex2'},
        readings: {'far': ExecutableReachability.unreachable},
      );
      expect(p.present.single.id, 'other');
      expect(p.unreachable.single.id, 'far');
      expect(p.absent.single.id, 'gone');
    });

    test('another environment\'s rows are not this sweep\'s', () {
      final wsl = AgentInstallation(
        id: 'w',
        agentId: 'codex',
        executable: const EnvironmentPath(environmentId: 'wsl:U', path: '/c'),
        createdAt: t0,
      );
      final p = plan([wsl], const []);
      expect(p.absent, isEmpty);
      expect(p.present, isEmpty);
    });

    test('the answer travels whole', () {
      final done = InstallationsReconciled(
        present: [row('a', r'C:\a.exe', version: '1')],
        versionChanges: const [InstallationVersionChange('codex', '0', '1')],
        pathChanges: const [InstallationPathChange('codex', 'x', 'y')],
      );
      final back = InstallationsReconciled.fromJson(done.toJson());
      expect(back.present, done.present);
      expect(back.versionChanges.single.to, '1');
      expect(back.pathChanges.single.to, 'y');
    });

    test('a path another row of the same agent holds is taken', () {
      final rows = [row('a', r'C:\a.exe'), row('b', r'C:\b.exe')];
      expect(installationPathTaken(rows, rows[1], r'C:\a.exe'), isTrue);
      expect(installationPathTaken(rows, rows[1], r'C:\c.exe'), isFalse);
    });
  });

  group('usage history', () {
    const account = 'claudeCode@windows';
    AgentUsage reading(DateTime at, {double five = 20}) => AgentUsage(
      fetchedAt: at.add(const Duration(milliseconds: 400)),
      windows: [
        UsageWindow(
          label: '5-hour',
          percent: five,
          resetsAt: DateTime.utc(2026, 9, 26, 14),
          span: const Duration(hours: 5),
        ),
        const UsageWindow(label: 'Gemini Code Assist'),
      ],
    );

    test('one candidate per measured window, to the second', () {
      final samples = usageSamplesOf(account, reading(t0));
      expect(samples.single.windowLabel, '5-hour');
      expect(samples.single.recordedAt, t0);
      expect(samples.single.span, const Duration(hours: 5));
    });

    test('an unchanged window waits for the heartbeat; a drifted reset is '
        'the same reset', () {
      final first = usageSamplesOf(account, reading(t0)).single;
      final soon = usageSamplesOf(
        account,
        reading(t0.add(const Duration(minutes: 3))),
      ).single;
      expect(usageSampleWorthKeeping(first, null), isTrue);
      expect(usageSampleWorthKeeping(soon, first), isFalse);
      final drifted = UsageSample(
        accountKey: account,
        windowLabel: '5-hour',
        percent: 20,
        resetsAt: DateTime.utc(2026, 9, 26, 14, 0, 40),
        recordedAt: t0.add(const Duration(minutes: 6)),
      );
      expect(usageSampleWorthKeeping(drifted, first), isFalse);
      final beat = usageSamplesOf(
        account,
        reading(t0.add(kUsageHistoryHeartbeat)),
      ).single;
      expect(usageSampleWorthKeeping(beat, first), isTrue);
    });

    test('a change is kept; the same moment or an older one is not', () {
      final first = usageSamplesOf(account, reading(t0)).single;
      final changed = usageSamplesOf(
        account,
        reading(t0.add(const Duration(minutes: 3)), five: 24),
      ).single;
      expect(usageSampleWorthKeeping(changed, first), isTrue);
      final same = usageSamplesOf(account, reading(t0, five: 31)).single;
      expect(usageSampleWorthKeeping(same, first), isFalse);
      final older = usageSamplesOf(
        account,
        reading(t0.subtract(const Duration(minutes: 5)), five: 40),
      ).single;
      expect(usageSampleWorthKeeping(older, first), isFalse);
    });

    test('a sample travels whole', () {
      final sample = usageSamplesOf(account, reading(t0)).single;
      expect(usageSampleFromJson(usageSampleToJson(sample)), sample);
    });
  });

  group('saved accounts', () {
    final claude = ClaudeAccount(
      id: 'a1',
      email: 'me@x.com',
      organizationUuid: 'org',
      claudeAiOauth: const {'accessToken': 'secret-token'},
      oauthAccount: const {'emailAddress': 'me@x.com'},
      capturedAt: t0,
    );
    final codex = CodexAccount(
      id: 'c1',
      accountId: 'acct',
      auth: const {'tokens': 'secret-token'},
      capturedAt: t0,
    );

    test('the wire carries credentials only when asked', () {
      expect('${claudeAccountToJson(claude)}', isNot(contains('secret')));
      expect('${codexAccountToJson(codex)}', isNot(contains('secret')));
      expect(
        claudeAccountFromJson(
          claudeAccountToJson(claude, credentials: true),
        ).claudeAiOauth['accessToken'],
        'secret-token',
      );
      expect(
        codexAccountFromJson(codexAccountToJson(codex, credentials: true)).auth,
        codex.auth,
      );
    });

    test('an account without credentials cannot be saved', () {
      expect(claudeAccountProblem(claude), isNull);
      expect(
        claudeAccountProblem(claudeAccountWithoutCredentials(claude)),
        contains('sign-in'),
      );
      expect(codexAccountProblem(codex), isNull);
      expect(
        codexAccountProblem(codexAccountWithoutCredentials(codex)),
        contains('sign-in'),
      );
    });

    test('orders follow the tables', () {
      final b = claudeAccountFromJson({
        ...claudeAccountToJson(claude),
        'id': 'b',
        'email': 'a@x.com',
      });
      expect(([claude, b]..sort(compareClaudeAccounts)).first.id, 'b');
    });
  });
}
