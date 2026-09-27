import 'dart:io';

import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_git/git.dart';
import 'package:karmashala_git/store.dart' show WorktreeSetupDao;
import 'package:karmashala_git/worktrees.dart';
import 'package:karmashala_host/src/automations/daemon_checkout_facts.dart';
import 'package:karmashala_host/src/companion/daemon_worktrees.dart';
import 'package:karmashala_host/src/domain/session_registry.dart';
import 'package:karmashala_host/src/pty/fake_pty.dart';
import 'package:test/test.dart';

import '../mcp/tools/repo_tool_fixture.dart';

/// A worktree's setup command, run by the server as a session of its own —
/// **named like a desktop pane**, so the app opens a pane on it and attaches
/// (it is watched, not run blind), and kept after it exits so its output can
/// still be read.
void main() {
  late RepoToolFixture f;
  late FakePtyLauncher launcher;
  late SessionRegistry registry;
  late List<WorktreeSetupReport> reports;
  late String app;
  late String appId;

  setUp(() {
    f = RepoToolFixture();
    app = f.repository(f.path('work/app'));
    appId = f
        .project('Work', f.path('work'), found: [app])
        .repositories
        .single
        .id;
    launcher = FakePtyLauncher();
    registry = SessionRegistry(launcher: launcher);
    reports = [];
    WorktreeSetupDao(f.database).save(
      appId,
      const WorktreeSetup(command: ['make', 'setup']),
      RepoToolFixture.now,
    );
  });

  tearDown(() => f.dispose());

  WorktreeService service() => daemonWorktrees(
    database: f.database,
    registry: registry,
    // This machine's own kind, whatever the machine running the test is.
    facts: DaemonCheckoutFacts(
      CheckoutRows(f.database),
      windows: Platform.isWindows,
    ),
    newId: () => 'p1',
    record: reports.add,
  );

  test('runs as karmashala_local_setup-<id>, reported by its pane id, and is '
      'kept once it ends', () async {
    final created = await service().create(
      repo: f.here(app),
      worktreeName: 'spike',
      branch: 'spike',
    );
    expect(created.worktree.branch, 'spike');

    // The verdict names the pane a client opens; the host session is the one
    // a desktop pane of that id attaches to.
    final pane = reports.last.command!.paneId;
    expect(pane, 'setup-p1');
    expect(worktreeSetupHostSessionId(pane!), 'karmashala_local_setup-p1');
    final session = registry.find('karmashala_local_setup-p1');
    expect(session, isNotNull);
    expect(launcher.started.single.argv, ['make', 'setup']);

    // It exits: the verdict follows, and the record — its output — stays.
    launcher.handles.single.emit('done\n'.codeUnits);
    launcher.handles.single.finish(0);
    await session!.drained;
    await Future<void>.delayed(Duration.zero);
    expect(reports.last.command!.result, WorktreeCommandResult.succeeded);
    expect(registry.find('karmashala_local_setup-p1'), isNotNull);
  });

  test('a command for another environment is not run here', () async {
    // The verdict says so rather than running it in the wrong place.
    final facts = DaemonCheckoutFacts(
      CheckoutRows(f.database),
      windows: !Platform.isWindows,
    );
    final elsewhere = daemonWorktrees(
      database: f.database,
      registry: registry,
      facts: facts,
      newId: () => 'p2',
      record: reports.add,
      environmentOf: (repo) => f.reach.environmentOf(repo),
    );
    await elsewhere.create(
      repo: f.here(app),
      worktreeName: 'other',
      branch: 'other',
    );
    expect(launcher.started, isEmpty);
    expect(
      reports.last.command!.result,
      WorktreeCommandResult.refusedNoPane,
    );
  });
}
