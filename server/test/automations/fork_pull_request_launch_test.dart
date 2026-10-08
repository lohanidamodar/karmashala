import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_git/worktrees.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/automations/hosted_agent_launcher.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Against **real git**, with a fake GitHub — a bare repository serving
/// `refs/pull/7/head`: a pull request run from a fork starts its agent in a
/// worktree on the fork's head, though no remote of the checkout has the
/// fork's branch, and its branch shares a name with the base's own.
void main() {
  final hasGit = Process.runSync('git', ['--version']).exitCode == 0;
  final t0 = DateTime.utc(2026, 10, 8, 12);

  late Directory tmp;
  late String base;
  late String fork;
  late String checkout;
  late AppDatabase database;
  late FakePtyLauncher pty;
  late SessionRegistry registry;

  String git(String dir, List<String> args) {
    final result = Process.runSync('git', [
      '-C',
      dir,
      '-c',
      'user.name=t',
      '-c',
      'user.email=t@t',
      '-c',
      'commit.gpgsign=false',
      ...args,
    ]);
    if (result.exitCode != 0) fail('git $args: ${result.stderr}');
    return (result.stdout as String).trim();
  }

  String commit(String dir, String name, String text) {
    File(p.join(dir, name)).writeAsStringSync(text);
    git(dir, ['add', name]);
    git(dir, ['commit', '-q', '-m', name]);
    return git(dir, ['rev-parse', 'HEAD']);
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ks-fork-pr');
    base = p.join(tmp.path, 'base.git');
    fork = p.join(tmp.path, 'fork');
    checkout = p.join(tmp.path, 'shop');
    Directory(base).createSync();
    git(base, ['init', '-q', '--bare', '-b', 'main']);
    Directory(fork).createSync();
    git(fork, ['init', '-q', '-b', 'main']);
    commit(fork, 'a.txt', 'a\n');
    git(fork, ['push', '-q', base, 'main']);
    git(tmp.path, ['clone', '-q', base, checkout]);

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
  });

  tearDown(() async {
    for (final handle in pty.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
    database.close();
    tmp.deleteSync(recursive: true);
  });

  test(
    'a fork\'s pull request runs on refs/pull/<n>/head in pr/<n>-<branch>',
    () async {
      final forkHead = commit(fork, 'fix.txt', 'the fix\n');
      // What GitHub does when the fork opens pull request 7.
      git(fork, ['push', '-q', base, 'HEAD:refs/pull/7/head']);
      final rows = CheckoutRows(database);
      final environment = rows.environment('local')!;
      final launcher = HostedAgentLauncher(
        registry: registry,
        sessions: SessionDao(database),
        mcp: SessionMcpAccessPoint(mcp: null, configDirectory: tmp.path),
        now: () => t0,
        newId: () => 's1',
        hostEnvironment: const {},
        environmentOf: rows.environment,
        worktrees: WorktreeService(
          runnerFactory: const CommandRunnerFactory(),
          environmentOf: (_) => environment,
        ),
      );
      final automation = Automation(
        id: 'auto-1',
        repositoryId: 'r1',
        name: 'Fix failing checks',
        schedule: AutomationSchedule.once(t0),
        agentInstallationId: 'a1',
        prompt: 'fix it',
        permissionMode: null,
        enabled: true,
        armedAt: t0,
        github: const AutomationGithubTrigger(
          kind: GithubTriggerKind.checkFailed,
          repository: 'someone/shop',
        ),
      );

      final id = await launcher.launch(
        automation,
        rows.repository('r1')!,
        rows.installation('a1')!,
        pullRequest: PullRequestCheckout.of(automation.github, const {
          'github.pr.number': '7',
          'github.pr.branch': 'main',
          'github.pr.fork': 'yes',
        }),
      );

      final session = SessionDao(database).getById(id)!;
      final worktree = session.worktree!.path;
      expect(git(worktree, ['rev-parse', '--abbrev-ref', 'HEAD']), 'pr/7-main');
      expect(git(worktree, ['rev-parse', 'HEAD']), forkHead);
      expect(pty.started.single.workingDirectory, worktree);
      // The base's own main is left as it was.
      expect(git(checkout, ['rev-parse', 'main']), isNot(forkHead));
    },
    skip: hasGit ? false : 'needs git',
  );
}
