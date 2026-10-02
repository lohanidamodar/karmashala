import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

/// A session on an agent somebody added (an `acp_agents` row) is named by
/// the row — its name, never its adapter id — wherever the explorer says
/// which agent a session runs on.
void main() {
  late TestMachine db;

  setUp(() {
    db = TestMachine();
    final server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.acpAgentRows.insert(
      AcpAgentRow(
        id: 'row-1',
        name: 'Mine',
        command: 'mine',
        args: const ['--acp'],
        createdAt: testTime,
      ),
    );
    server.installationRows.insert(
      agentInstallation(
        agentId: acpAgentIdFor('row-1'),
        path: r'C:\Users\me\.bin\mine.exe',
      ),
    );
    server.sessionRows.insert(session(title: 'On my agent'));
  });

  testWidgets('a session row names a row-backed agent by its name', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          await db.server.override(),
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(),
          ),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          availableSystemTerminalsProvider.overrideWith(
            (ref) async => const <SystemTerminal>[],
          ),
          autoImportRunnerProvider.overrideWithValue(
            (_) async => const ImportSummary(),
          ),
          agentSessionStatusProvider.overrideWith(
            (ref, id) => const Stream<AgentStatusReport>.empty(),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: ExplorerPanel())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Demo'));
    await tester.pumpAndSettle();

    expect(find.text('On my agent'), findsOneWidget);
    // The card says the agent on its glyph's hover and in its semantics.
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip && (widget.message?.contains('Mine') ?? false),
      ),
      findsWidgets,
    );
    expect(find.textContaining(acpAgentIdPrefix), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip &&
            (widget.message?.contains(acpAgentIdPrefix) ?? false),
      ),
      findsNothing,
    );
  });
}
