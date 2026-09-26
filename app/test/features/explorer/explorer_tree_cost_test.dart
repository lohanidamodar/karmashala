import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/explorer/application/explorer_tree_nodes.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_ssh/connection.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import '../../support/test_machine.dart';

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
/// the sweep is per build — the scope bar's list of machines is read in the
/// same pass as the tree — and a group nobody opened costs nothing.
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
  /// a host reached over SSH, all in one context — one header and three
  /// machines whatever the count, so the number below is about the projects.
  CountingMachine seed(FakeDataServer server, int count) {
    final db = CountingMachine();
    final environments = server.environmentRows;
    environments.upsert(windowsEnv());
    environments.upsert(wslEnv());
    environments.upsert(sshEnvFixture());
    server.sshHostRows.upsert(_buildBox());
    const ids = ['windows', 'wsl:Ubuntu', 'ssh:h1'];
    server.workspaceRows.insert(
      Workspace(id: 'w1', name: 'Client work', createdAt: testTime),
    );
    final projects = server.projectRows;
    for (var i = 0; i < count; i++) {
      projects.insert(
        project(
          id: 'p$i',
          name: 'Project $i',
          environmentId: ids[i % ids.length],
          workspaceId: 'w1',
          path:
              r'C:\src\p'
              '$i',
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
    final server = FakeDataServer();
    final db = seed(server, count);
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        ...fakeTerminalOverrides(machine: db),
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
      // The control arm: the one context folded away, so no project is drawn.
      container
          .read(settingsControllerProvider.notifier)
          .toggleExplorerNodeCollapsed(contextHeaderId('w1'));
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
      // A project's own second line names its machine while every machine is
      // listed together — drawn only when the group is open.
      headerShown: find.text('Windows').evaluate().isNotEmpty,
    );
  }

  group('drawing the Explorer across machines', () {
    final on = <int, ({int sweeps, int statements})>{};
    final off = <int, ({int sweeps, int statements})>{};

    for (final count in scale) {
      testWidgets('over $count projects, folded', (tester) async {
        final result = await pump(tester, count, grouped: false);
        off[count] = (sweeps: result.sweeps, statements: result.statements);
      });

      testWidgets('over $count projects, open', (tester) async {
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
        for (final count in scale)
          count: on[count]!.sweeps - off[count]!.sweeps,
      };
      final extra = {
        for (final count in scale)
          count: on[count]!.statements - off[count]!.statements,
      };
      // Since slice 1d the environments are the server's, read from the data
      // client's copy: the tree sweeps the table not once, let alone per row.
      expect(
        {for (final count in scale) on[count]!.sweeps + off[count]!.sweeps},
        {0},
        reason: 'no environment sweep, open or folded: $sweeps',
      );
      // Nor does drawing the groups open cost more statements as the
      // workspace grows.
      expect(
        on[100]!.statements - on[10]!.statements,
        lessThan(10),
        reason: 'opening the groups does not grow with the workspace: $extra',
      );
      expect(
        off[100]!.statements - off[10]!.statements,
        lessThan(10),
        reason:
            'and what is left when everything is folded does not grow '
            'with the workspace either: $extra',
      );
    });
  });
}
