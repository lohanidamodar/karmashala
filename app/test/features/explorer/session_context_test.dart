import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/explorer/application/session_context.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/workspace_mirror.dart';
import '../terminal/fake_instance.dart';

/// Which checkout a session's work belongs to, and what follows it.
///
/// The bug this answers: the side panel described whatever row was last clicked
/// in the Explorer, so a user typing into an agent that runs three folders down
/// a hub project was shown the hub's diff, branch and forge links.
void main() {
  late AppDatabase db;
  late ProviderContainer container;

  /// A hub project holding two checkouts: the hub itself, and a clone nested
  /// inside it — the shape that made the reported bug visible.
  const hub = r'C:\src\demo';
  const nested = r'C:\src\demo\projects\app\app';

  setUp(() async {
    db = AppDatabase.memory();
    final server = FakeDataServer()..mirrorInto(db);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    server.projectRows.insert(project(path: hub));
    server.repositoryRows
      ..insert(repository(id: 'hub', name: 'demo', path: hub))
      ..insert(repository(id: 'nested', name: 'app', path: nested));
    AgentInstallationDao(db).insert(agentInstallation());
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        await server.override(),
      ],
    );
    addTearDown(container.dispose);
  });
  tearDown(() => db.close());

  SessionContext context() => container.read(sessionContextProvider);

  test('a session resolves to the deepest checkout that contains it', () {
    // The row says "hub" — that is the repository it was created against — but
    // the agent is working in the clone underneath. The deeper checkout is the
    // one whose diff, branch and remote the user means.
    SessionDao(db).insert(
      session(
        repositoryId: 'hub',
        useWorktree: true,
        worktree: const EnvironmentPath(environmentId: 'windows', path: nested),
      ),
    );

    expect(context().follow('s1')?.id, 'nested');
    expect(container.read(selectedRepositoryIdProvider), 'nested');
    // And the project above it, or the tree would still be pointing elsewhere.
    expect(container.read(selectedProjectIdProvider), 'p1');
  });

  test('a session no checkout contains keeps its own repository', () {
    // A different environment: paths are never compared across two, so nothing
    // contains this and the row's own repository is the honest answer.
    SessionDao(db).insert(
      session(
        repositoryId: 'nested',
        useWorktree: true,
        worktree: const EnvironmentPath(
          environmentId: 'wsl:Ubuntu',
          path: '/home/me/work',
        ),
      ),
    );

    expect(context().follow('s1')?.id, 'nested');
  });

  test('a session with no worktree resolves through its repository', () {
    SessionDao(db).insert(session(repositoryId: 'nested'));

    expect(context().follow('s1')?.id, 'nested');
  });

  test('following a session that does not exist changes nothing', () {
    container.read(selectedRepositoryIdProvider.notifier).select('hub');

    expect(context().follow('gone'), isNull);
    expect(container.read(selectedRepositoryIdProvider), 'hub');
  });

  test('the active session is the one in the pane on screen', () {
    final terminals = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    terminals.openTab(TerminalProfile.powerShell);
    final paneId = container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .layout
        .panes
        .single;
    SessionDao(db)
      ..insert(session(repositoryId: 'nested'))
      ..updatePaneId('s1', paneId);

    expect(container.read(activePaneSessionIdProvider), 's1');

    // A plain shell tab is not a session, and answering null is what leaves the
    // Explorer's own selection in charge.
    terminals.openTab(TerminalProfile.powerShell);
    expect(container.read(activePaneSessionIdProvider), isNull);
  });

  test('splitting a session\'s tab does not lose the session', () {
    // Reported as "once split, bottom statusbar is gone": splitting focuses the
    // new pane, a new plain shell has no session, and everything keyed on the
    // focused pane alone went away with it. A shell opened beside a session is
    // still a shell opened beside that session.
    final terminals = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    terminals.openTab(TerminalProfile.powerShell);
    final paneId = container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .layout
        .panes
        .single;
    SessionDao(db)
      ..insert(session(repositoryId: 'nested'))
      ..updatePaneId('s1', paneId);

    terminals.splitPaneWith(SplitAxis.vertical, TerminalProfile.commandPrompt);

    expect(container.read(activePaneSessionIdProvider), 's1');
  });
}
