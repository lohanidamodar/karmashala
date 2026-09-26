import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/application/explorer_agent_filter.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../scale/scale_harness.dart';
import '../terminal/fake_instance.dart';

/// **What narrowing the Explorer to one agent costs, counted as a difference.**
///
/// The gate this is written against is the one `explorer_sections_cost_test`
/// names: `quiet_soak_cost_test.dart` pins **zero** database statements over
/// 180 autosave ticks at a hundred idle panes, and the Explorer's own tree
/// draws a project from two indexed reads and no git. A filter that asked which
/// agent runs a session **per session** would have broken both — 403 statements
/// at 400 sessions is exactly the failure `session_switch_cost_test` was
/// written for, and this feature has to have an opinion about every row in the
/// list rather than only the cards on screen.
///
/// It does not, and the reason is where agent identity lives. A native session
/// names an `agent_installations` row and an imported one names its CLI
/// directly, and that table is one row per `(agent, environment)` — six rows on
/// a machine with three agents in Windows and WSL, whatever the workspace holds.
/// So the whole filter is **one sweep of a tiny table**, read once for the
/// panel and reused by the tree and the sections alike.
///
/// Measured as a difference against the same panel with the filter off, the way
/// the empty-section filter's own numbers were, because the question is not
/// what the Explorer costs — it is what narrowing it adds to that.
bool _isAgentSweep(String sql) =>
    sql.startsWith('SELECT * FROM agent_installations ORDER BY');

void main() {
  const scale = [1, 10, 100];

  /// [count] sessions spread evenly across the three agents, on one project.
  CountingDatabase seed(int count) {
    final db = CountingDatabase();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project(id: 'p1', name: 'Hub', path: r'C:\hub'));
    RepositoryDao(db).insert(
      repository(id: 'r1', projectId: 'p1', name: 'hub', path: r'C:\hub'),
    );
    // Codex first, so the one-session workspace has a row that survives the
    // narrowing and the "filter on" case is measuring work rather than a
    // shortcut past it.
    const agents = [AgentIds.codex, AgentIds.claudeCode, AgentIds.antigravity];
    final installations = AgentInstallationDao(db);
    for (final agent in agents) {
      installations.insert(agentInstallation(id: 'a-$agent', agentId: agent));
    }
    for (var i = 0; i < count; i++) {
      SessionDao(db).insert(
        session(
          id: 's$i',
          title: 'Session $i',
          agentInstallationId: 'a-${agents[i % agents.length]}',
          status: SessionStatus.running,
        ),
      );
    }
    return db;
  }

  /// Mounts the Explorer over [count] sessions with the project expanded, and
  /// reports what deciding what to draw cost — counted from the frame the
  /// widget went up.
  Future<({ProviderContainer container, int sweeps, int cards})> pump(
    WidgetTester tester,
    int count, {
    required bool narrow,
  }) async {
    tester.view.physicalSize = const Size(460, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = seed(count);
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('n-')),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
        ),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => const Stream<AgentStatusReport>.empty(),
        ),
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        autoImportRunnerProvider.overrideWithValue(
          (_) async => const ImportSummary(),
        ),
      ],
    );
    addTearDown(container.dispose);
    if (narrow) {
      container
          .read(settingsControllerProvider.notifier)
          .setExplorerAgentFilter(const {AgentIds.codex});
    }
    db.reset();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: ExplorerPanel())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hub'));
    await tester.pumpAndSettle();
    return (
      container: container,
      sweeps: db.statements.where(_isAgentSweep).length,
      cards: tester.widgetList(find.byType(SessionCard)).length,
    );
  }

  group('narrowing the Explorer to one agent', () {
    final on = <int, int>{};
    final off = <int, int>{};
    final onCards = <int, int>{};
    final offCards = <int, int>{};

    for (final count in scale) {
      testWidgets('over $count sessions, filter off', (tester) async {
        final result = await pump(tester, count, narrow: false);
        off[count] = result.sweeps;
        offCards[count] = result.cards;
        expect(
          result.container.exists(sessionAgentsProvider),
          isFalse,
          reason:
              'an Explorer nobody has narrowed must not read the installations '
              'table at all — the unfiltered path is the identity',
        );
      });

      testWidgets('over $count sessions, filter on', (tester) async {
        final result = await pump(tester, count, narrow: true);
        on[count] = result.sweeps;
        onCards[count] = result.cards;
        expect(
          result.cards,
          greaterThan(0),
          reason:
              'the rows really were filed, so the number below is the cost '
              'of doing the work rather than of skipping it',
        );
      });
    }

    test('costs one read of a table that does not grow with the workspace', () {
      expect(on.keys, containsAll(scale));
      expect(off.keys, containsAll(scale));
      // ignore: avoid_print
      print('AGENT-FILTER sweeps on=$on off=$off');
      expect(
        off.values.toSet(),
        orderedEquals([0]),
        reason: 'the panel does not sweep installations to begin with: $off',
      );
      for (final count in scale) {
        expect(
          on[count]! - off[count]!,
          1,
          reason:
              'deciding which agent runs every session in the workspace reads '
              'the installations table once and no more, at $count sessions: '
              '${on[count]} against ${off[count]}',
        );
      }
      // ignore: avoid_print
      print('AGENT-FILTER cards on=$onCards off=$offCards');
      // Ten, not a hundred: the Explorer's `ListView` inflates only the cards
      // on screen — that is `explorer_panel_scale_test`'s property, and it caps
      // both columns at a screenful long before a hundred. Ten rows all fit, so
      // ten is where the narrowing is visible as a number.
      expect(
        onCards[10]!,
        lessThan(offCards[10]!),
        reason:
            'a filter whose cost is flat because it does nothing is not the '
            'claim being made: $onCards against $offCards',
      );
    });

    testWidgets('and nothing at all on a tree nobody has touched', (
      tester,
    ) async {
      final result = await pump(tester, 100, narrow: true);
      final db = result.container.read(databaseProvider) as CountingDatabase;
      final git = FakeCommandRunner();
      db.reset();

      // A second of frames over a tree where nothing moved. The filter's answer
      // is a memoised provider kept alive by the expanded project, so
      // re-reading it is what a rebuilding widget does and it must cost
      // nothing.
      for (var frame = 0; frame < 180; frame++) {
        result.container.read(visibleProjectSessionsProvider('p1'));
      }
      await tester.pump();

      // ignore: avoid_print
      print('AGENT-FILTER idle statements=${db.count}');
      expect(
        db.statements,
        isEmpty,
        reason:
            'a filter that re-queried per rebuild is the whole regression this '
            'file exists to catch: ${db.statements}',
      );
      expect(
        git.requests,
        isEmpty,
        reason:
            'and it may never start a process, which is the constraint '
            'saved sections were built to',
      );
    });
  });
}
