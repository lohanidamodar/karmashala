import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/ssh/data/ssh_host_dao.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/data/system_terminal_service.dart';
import 'package:karmashala_ssh/connection.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../scale/scale_harness.dart';
import '../terminal/fake_instance.dart';

/// **What drawing the Explorer by machine instead of by project costs.**
///
/// Reported 2026-09-13 as *"grouping by environment is very slow and feels
/// unresponsive"*. Measured against the reporter's own workspace in a debug
/// build it is 60 ms cold and 14-20 ms warm, so the spine is not the cost —
/// but nothing pinned that, and the shape that would make it true is one a
/// reasonable change could introduce at any time: reading the environment of
/// each project *per row* rather than sweeping the table once.
///
/// So this counts the sweep as a difference against the same panel ungrouped,
/// the way `explorer_agent_filter_cost_test` counts its own. The claim is not
/// that grouping is free; it is that what it adds does not grow with the
/// workspace.
bool _isEnvSweep(String sql) =>
    sql.startsWith('SELECT * FROM execution_environments ORDER BY');

SshHost _buildBox() => SshHost(
  id: 'h1',
  name: 'build-box',
  host: 'build.example.com',
  port: 22,
  username: 'dev',
  authMethod: SshAuthMethod.password,
  createdAt: testTime,
);

void main() {
  const scale = [1, 10, 100];

  /// [count] projects spread evenly over this machine, a WSL distribution and
  /// a host reached over SSH — three groups whatever the count, so the number
  /// below is about the projects and not about the headers.
  CountingDatabase seed(int count) {
    final db = CountingDatabase();
    final environments = ExecutionEnvironmentDao(db);
    environments.upsert(windowsEnv());
    environments.upsert(wslEnv());
    environments.upsert(sshEnvFixture());
    SshHostDao(db).upsert(_buildBox());
    const ids = ['windows', 'wsl:Ubuntu', 'ssh:h1'];
    final projects = ProjectDao(db);
    for (var i = 0; i < count; i++) {
      projects.insert(
        project(
          id: 'p$i',
          name: 'Project $i',
          environmentId: ids[i % ids.length],
          path: r'C:\src\p' '$i',
        ),
      );
    }
    return db;
  }

  Future<({int sweeps, int statements, bool headerShown})> pump(
    WidgetTester tester,
    int count, {
    required bool grouped,
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
    if (grouped) {
      container
          .read(settingsControllerProvider.notifier)
          .setExplorerGroupByEnvironment(true);
    }
    db.reset();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: ExplorerPanel())),
      ),
    );
    await tester.pumpAndSettle();
    return (
      sweeps: db.statements.where(_isEnvSweep).length,
      statements: db.statements.length,
      // The first group's own name, which only the grouped spine draws as a
      // heading. `findsWidgets`: a project row carries an environment badge
      // with the same word on it.
      headerShown: find.text('Windows').evaluate().isNotEmpty,
    );
  }

  group('drawing the Explorer by machine', () {
    final on = <int, ({int sweeps, int statements})>{};
    final off = <int, ({int sweeps, int statements})>{};

    for (final count in scale) {
      testWidgets('over $count projects, by project', (tester) async {
        final result = await pump(tester, count, grouped: false);
        off[count] = (sweeps: result.sweeps, statements: result.statements);
      });

      testWidgets('over $count projects, by environment', (tester) async {
        final result = await pump(tester, count, grouped: true);
        on[count] = (sweeps: result.sweeps, statements: result.statements);
        expect(
          result.headerShown,
          isTrue,
          reason:
              'the groups really were drawn, so the numbers below are the cost '
              'of doing the work rather than of skipping it',
        );
      });
    }

    test('adds a sweep of a table that does not grow with the workspace', () {
      expect(on.keys, containsAll(scale));
      expect(off.keys, containsAll(scale));
      // ignore: avoid_print
      print('GROUPING sweeps on=$on off=$off');
      final sweeps = {
        for (final count in scale) count: on[count]!.sweeps - off[count]!.sweeps,
      };
      final extra = {
        for (final count in scale)
          count: on[count]!.statements - off[count]!.statements,
      };
      // Ten times the projects, the same extra work: the headers sweep the
      // environment table once per build and read the SSH host once per group,
      // never once per project. A delta that moves with the count is the
      // per-row read this test exists to catch.
      expect(
        sweeps[100],
        sweeps[10],
        reason: 'the header sweep is per build, not per project: $sweeps',
      );
      expect(
        extra[100],
        extra[10],
        reason: 'grouping costs the same at 100 projects as at 10: $extra',
      );
      for (final count in scale) {
        expect(
          extra[count],
          lessThan(count + 1),
          reason:
              'grouping must not add a statement per project at $count: '
              '${on[count]} against ${off[count]}',
        );
      }
    });
  });
}
