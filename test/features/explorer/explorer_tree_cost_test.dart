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

/// **What the Explorer's tree costs, counted as table sweeps.**
///
/// Reported 2026-09-13 as *"grouping by environment is very slow and feels
/// unresponsive"*. Measured against the reporter's own workspace it was 60 ms
/// cold and 14-20 ms warm, so the spine was never the cost — but the shape
/// that *would* make it the cost is one a reasonable change reintroduces
/// easily, and this file caught it once already: `projectPathMissingProvider`
/// swept `execution_environments` once per WSL project, 34 times at a hundred.
///
/// Two claims, both about growth rather than about absolute numbers:
/// the sweep is per build, and a machine nobody opened costs nothing.
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
    if (!grouped) {
      // The spine is always the machine now, so the "ungrouped" arm of this
      // measurement is the tree with every machine folded away.
      for (final id in ['windows', 'wsl:Ubuntu', 'ssh:h1']) {
        container
            .read(settingsControllerProvider.notifier)
            .toggleExplorerNodeCollapsed('env:$id');
      }
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
      // Ten times the projects, no more sweeps: the environment table is read
      // once for the tree, never once per row. Fewer is allowed — rows are
      // lazy, and a WSL project scrolled off screen asks nothing of it.
      expect(
        on[100]!.sweeps,
        lessThanOrEqualTo(on[10]!.sweeps),
        reason: 'a sweep that grows with the workspace is the per-row read '
            'this test exists to catch: $sweeps',
      );
      // A folded machine draws no project, so it pays for none of them.
      expect(
        off[100]!.statements,
        lessThan(on[100]!.statements),
        reason: 'folding every machine away must actually save the work: '
            '${off[100]} against ${on[100]}',
      );
      expect(
        off[100]!.statements - off[10]!.statements,
        lessThan(10),
        reason: 'and what is left when everything is folded does not grow '
            'with the workspace either: $extra',
      );
    });
  });
}
