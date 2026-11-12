import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart' show AgentInstallation, PathProbe;
import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/worktrees.dart';
import 'package:karmashala_host/data.dart' show DataService;
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/automations/daemon_checkout_facts.dart';
import 'package:karmashala_host/src/automations/hosted_agent_launcher.dart';
import 'package:karmashala_host/src/sessions/launch/server_session_launcher.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final class _Everywhere implements PathProbe {
  const _Everywhere();
  @override
  bool? fileExists(String path) => true;
  @override
  bool isLink(String path) => false;
  @override
  String? linkTarget(String path) => null;
}

/// Against **real git**: a worktree Karmashala makes for a new session is
/// marked trusted in the agent's settings before the agent starts in it; the
/// project folder a person registered is not trusted through that path
/// (registered_project_trust_test covers the setting that does).
void main() {
  final hasGit = Process.runSync('git', ['--version']).exitCode == 0;
  final t0 = DateTime.utc(2026, 11, 12, 12);

  late Directory tmp;
  late String checkout;
  late AppDatabase database;
  late FakePtyLauncher pty;
  late SessionRegistry registry;
  late ServerSessionLauncher launches;
  late List<(String, EnvironmentPath, int)> trusted;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ks-tree-trust');
    checkout = p.join(tmp.path, 'shop');
    Directory(checkout).createSync();
    for (final args in [
      ['init', '-q', '-b', 'main'],
      ['commit', '-q', '--allow-empty', '-m', 'start'],
    ]) {
      final result = Process.runSync('git', [
        '-C',
        checkout,
        '-c',
        'user.name=t',
        '-c',
        'user.email=t@t',
        '-c',
        'commit.gpgsign=false',
        ...args,
      ]);
      if (result.exitCode != 0) fail('git $args: ${result.stderr}');
    }

    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    database.execute(
      'INSERT INTO execution_environments (id, kind, name, created_at) '
      'VALUES (?, ?, ?, ?);',
      [
        'local',
        Platform.isWindows ? 'windowsNative' : 'localPosix',
        'Here',
        '$t0',
      ],
    );
    database.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      'created_at) VALUES (?, ?, ?, ?, ?, ?);',
      ['r1', 'p1', 'shop', 'local', checkout, '$t0'],
    );
    database.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      'executable_path, created_at, executable_by_user) '
      'VALUES (?, ?, ?, ?, ?, ?);',
      ['a1', AgentIds.claudeCode, 'local', '/bin/claude', '$t0', 1],
    );
    pty = FakePtyLauncher();
    registry = SessionRegistry(launcher: pty);
    trusted = [];
    Future<void> trust(
      AgentInstallation installation,
      EnvironmentPath folder,
    ) async => trusted.add((installation.id, folder, pty.started.length));
    final rows = CheckoutRows(database);
    final environment = rows.environment('local')!;
    var ids = 0;
    launches = ServerSessionLauncher(
      launcher: HostedAgentLauncher(
        registry: registry,
        sessions: SessionDao(database),
        mcp: SessionMcpAccessPoint(mcp: null, configDirectory: tmp.path),
        now: () => t0,
        newId: () => 'new-${++ids}',
        hostEnvironment: const {},
        environmentOf: rows.environment,
        worktrees: WorktreeService(
          runnerFactory: const CommandRunnerFactory(),
          environmentOf: (_) => environment,
        ),
        trustCreatedWorktree: trust,
      ),
      registry: registry,
      sessions: SessionDao(database),
      rows: rows,
      facts: DaemonCheckoutFacts(rows, windows: Platform.isWindows),
      installationsIn: DataService(database).installationsIn,
      directoryPresent: (_) => true,
      pathProbe: const _Everywhere(),
      trustScratchFolder: trust,
    );
  });

  tearDown(() async {
    for (final handle in pty.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
    database.close();
    tmp.deleteSync(recursive: true);
  });

  test('a new session in a worktree of its own has the worktree trusted before '
      'its agent starts', () async {
    final started = await launches.start(
      const SessionStartSpec(
        repositoryId: 'r1',
        installationId: 'a1',
        title: 'Tree',
        worktree: true,
      ),
    );

    final worktree = started.session.worktree!;
    expect(worktree.path, isNot(checkout));
    expect(trusted, [('a1', worktree, 0)]);
    expect(pty.started.single.workingDirectory, worktree.path);
  }, skip: hasGit ? false : 'needs git');

  test(
    'a session in the registered project folder does not have it trusted',
    () async {
      await launches.start(
        const SessionStartSpec(
          repositoryId: 'r1',
          installationId: 'a1',
          title: 'Here',
        ),
      );

      expect(pty.started.single.workingDirectory, checkout);
      expect(trusted, isEmpty);
    },
    skip: hasGit ? false : 'needs git',
  );
}
