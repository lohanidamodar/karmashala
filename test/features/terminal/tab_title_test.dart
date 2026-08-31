import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/agents/data/agent_installation_dao.dart';
import 'package:chitragupta/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:chitragupta/src/features/repositories/data/repository_dao.dart';
import 'package:chitragupta/src/features/sessions/application/session_providers.dart';
import 'package:chitragupta/src/features/sessions/application/session_ui_providers.dart';
import 'package:chitragupta/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:chitragupta/src/features/terminal/domain/agent_pane_launch.dart';
import 'package:chitragupta/src/features/terminal/domain/pane_layout.dart';
import 'package:chitragupta/src/features/terminal/domain/pane_title.dart';
import 'package:chitragupta/src/features/terminal/domain/terminal_profile.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_instance.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// What a terminal tab is called.
///
/// The reported bug: "i opened archlinux terminal tab, then started claude
/// session and then renamed the session, the tab doesn't update the title."
/// `TerminalInstance.title` is a final field captured when the pane was made,
/// so a rename could never reach it. The label is derived at display time now,
/// from the session's own row — one source of truth, and a rename shows without
/// a reopen or a restart.
void main() {
  group('a directory as a label', () {
    test('home is a tilde, whichever separator the platform uses', () {
      expect(directoryLabel(r'C:\Users\me', home: r'C:\Users\me'), '~');
      expect(directoryLabel('/home/me', home: '/home/me'), '~');
      expect(directoryLabel(r'C:\Users\me\', home: r'C:\Users\me'), '~');
    });

    test('one level below home keeps the tilde', () {
      expect(
        directoryLabel(r'C:\Users\me\projects', home: r'C:\Users\me'),
        '~/projects',
      );
    });

    test('deeper than that is the last two segments', () {
      expect(
        directoryLabel('/home/me/projects/chitragupta', home: '/home/me'),
        'projects/chitragupta',
      );
      expect(directoryLabel(r'C:\Windows\System32'), 'Windows/System32');
    });

    test('a root, and a single segment', () {
      expect(directoryLabel('/'), '/');
      expect(directoryLabel('/opt'), 'opt');
    });

    test('a WSL path under a Windows home is not mistaken for it', () {
      expect(
        directoryLabel('/home/me/src', home: r'C:\Users\me'),
        'me/src',
        reason: 'the home prefix does not match, so nothing is substituted',
      );
    });
  });

  group('through the controller', () {
    late AppDatabase db;
    late ProviderContainer container;
    late TerminalSessionsController controller;

    setUp(() {
      db = AppDatabase.memory();
      // A session row has foreign keys into all of these.
      ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
      ProjectDao(db).insert(project());
      RepositoryDao(db).insert(repository());
      AgentInstallationDao(db).insert(agentInstallation());
      container = fakeTerminalContainer(database: db);
      controller = container.read(terminalSessionsControllerProvider.notifier);
    });
    tearDown(() {
      container.dispose();
      db.close();
    });

    test('renaming a session renames its tab, with no reopen', () {
      container.read(sessionDaoProvider).insert(session(title: 'Work'));
      final opened = controller.openAgentTab(
        const AgentPaneLaunch(
          agentId: 'claude',
          executable: 'claude',
          sessionId: 's1',
          title: 'Work',
        ),
      );
      expect(controller.titleForTab(opened.tabId), 'Work');

      container.read(sessionDaoProvider).updateTitle('s1', 'Fix the parser');
      container.read(sessionsRevisionProvider.notifier).bump();

      expect(controller.titleForTab(opened.tabId), 'Fix the parser');
      // The pane itself was not touched: the title was never its to own.
      expect(controller.instanceFor(opened.paneId)!.title, 'Work');
    });

    test('a rename republishes, so the tab strip actually rebuilds', () {
      container.read(sessionDaoProvider).insert(session(title: 'Work'));
      controller.openAgentTab(
        const AgentPaneLaunch(
          agentId: 'claude',
          executable: 'claude',
          sessionId: 's1',
        ),
      );
      final before = container.read(terminalSessionsControllerProvider);

      container.read(sessionDaoProvider).updateTitle('s1', 'Renamed');
      container.read(sessionsRevisionProvider.notifier).bump();

      expect(
        container.read(terminalSessionsControllerProvider),
        isNot(same(before)),
        reason: 'a rename never touches a terminal, so this is what makes the '
            'strip notice',
      );
    });

    test('a renamed session survives a detach and reattach', () {
      container.read(sessionDaoProvider).insert(session(title: 'Work'));
      final opened = controller.openAgentTab(
        const AgentPaneLaunch(
          agentId: 'claude',
          executable: 'claude',
          sessionId: 's1',
        ),
      );
      container.read(sessionDaoProvider).updateTitle('s1', 'Renamed');
      container.read(sessionsRevisionProvider.notifier).bump();

      controller.closeTab(opened.tabId);
      final reattached = controller.reattachSession(opened.paneId)!;

      expect(controller.titleForTab(reattached), 'Renamed');
    });

    test('an agent pane with no session keeps its launch title', () {
      final opened = controller.openAgentTab(
        const AgentPaneLaunch(
          agentId: 'claude',
          executable: 'claude',
          title: 'Ad-hoc',
        ),
      );

      expect(controller.titleForTab(opened.tabId), 'Ad-hoc');
    });

    test('a plain shell with a directory is titled by it', () {
      final tabId = controller.openTab(
        TerminalProfile.powerShell,
        workingDirectory: r'C:\src\chitragupta',
      );

      expect(controller.titleForTab(tabId), 'src/chitragupta');
    });

    test('a plain shell with no directory keeps its profile label', () {
      final tabId = controller.openTab(TerminalProfile.powerShell);

      expect(controller.titleForTab(tabId), 'PowerShell');
    });

    test('a shell that names its own window wins over the directory', () {
      final tabId = controller.openTab(
        TerminalProfile.powerShell,
        workingDirectory: r'C:\src\chitragupta',
      );
      final pane = container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .layout
          .panes
          .single;

      // OSC 2 — what a shell's PROMPT_COMMAND or a TUI sends.
      controller.instanceFor(pane)!.terminal.write('\x1b]2;vim README.md\x07');

      expect(controller.titleForTab(tabId), 'vim README.md');
    });

    test('an agent session outranks the title the agent set for itself', () {
      // Claude Code and Codex both name their own window; letting that win
      // would put the rename back out of reach, which is the bug.
      container.read(sessionDaoProvider).insert(session(title: 'Work'));
      final opened = controller.openAgentTab(
        const AgentPaneLaunch(
          agentId: 'claude',
          executable: 'claude',
          sessionId: 's1',
        ),
      );
      controller.instanceFor(opened.paneId)!.terminal.write('\x1b]2;Claude\x07');

      expect(controller.titleForTab(opened.tabId), 'Work');
    });

    test('the pane count suffix survives all of it', () {
      final tabId = controller.openTab(
        TerminalProfile.powerShell,
        workingDirectory: r'C:\src\chitragupta',
      );
      controller.splitPane(SplitAxis.horizontal, TerminalProfile.powerShell);

      expect(controller.titleForTab(tabId), endsWith(' (2)'));
    });
  });
}
