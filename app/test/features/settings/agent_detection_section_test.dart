import 'package:agent_cli/discovery.dart'
    show AgentDiscoveryReport, AgentPathRepairReport, EnvironmentScanReport;
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/settings/presentation/agent_detection_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

const _registry = AgentRegistry([
  DataOnlyAgentAdapter(
    AgentDescriptor(
      id: AgentIds.claudeCode,
      displayName: 'Claude Code',
      binaries: AgentBinaries(windows: ['claude'], posix: ['claude']),
    ),
  ),
  DataOnlyAgentAdapter(
    AgentDescriptor(
      id: AgentIds.codex,
      displayName: 'Codex CLI',
      binaries: AgentBinaries(windows: ['codex'], posix: ['codex']),
    ),
  ),
]);

void main() {
  late TestMachine db;
  var installed = <String>{'claude'};

  FakeCommandRunner runner() => FakeCommandRunner(
    responder: (req) {
      if (req.executable == 'where') {
        return installed.contains(req.arguments.first)
            ? CommandResult(
                exitCode: 0,
                stdout: 'C:\\bin\\${req.arguments.first}.exe\r\n',
                stderr: '',
              )
            : const CommandResult(exitCode: 1, stdout: '', stderr: '');
      }
      return const CommandResult(exitCode: 0, stdout: '9.9.9', stderr: '');
    },
  );

  setUp(() {
    installed = {'claude'};
    db = TestMachine();
    FakeDataServer().runsOn(db);
    db.server.environmentRows.upsert(windowsEnv());
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          await db.server.override(),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          idGeneratorProvider.overrideWithValue(SequentialIdGenerator()),
          agentRegistryProvider.overrideWithValue(_registry),
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(fallback: runner()),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: AgentDetectionSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('offers a re-detect control before anything has been scanned', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Rescan'), findsOneWidget);
    expect(find.textContaining('Not scanned yet'), findsOneWidget);
  });

  /// What the server's sweep reports, as it would word it: [found] agents
  /// present of those the registry knows, [added] of them new.
  AgentDiscoveryReport report({required int found, int added = 0}) {
    final rows = [
      agentInstallation(),
      if (found > 1)
        agentInstallation(
          id: 'a2',
          agentId: AgentIds.codex,
          path: r'C:\bin\codex.exe',
        ),
    ].take(found).toList();
    return AgentDiscoveryReport([
      EnvironmentScanReport(
        environmentId: 'windows',
        environmentName: 'Windows',
        reachable: true,
        found: rows,
        added: rows.skip(found - added).toList(),
        missing: [if (found < 2) 'Codex CLI', if (found < 1) 'Claude Code'],
      ),
    ]);
  }

  testWidgets('reports what it found and what it did not', (tester) async {
    db.server.agentWork.onRepair = (_) =>
        AgentPathRepairReport(checkedAt: testTime, scan: report(found: 1));
    await pump(tester);
    await tester.tap(find.text('Rescan'));
    await tester.pumpAndSettle();

    expect(find.textContaining('1 agent'), findsOneWidget);
    // The half that this codebase has been burned by: an operation that
    // reports success while saying nothing about what it did not do.
    expect(find.textContaining('Codex CLI'), findsOneWidget);
  });

  testWidgets('says plainly when it found nothing', (tester) async {
    db.server.agentWork.onRepair = (_) =>
        AgentPathRepairReport(checkedAt: testTime, scan: report(found: 0));
    await pump(tester);
    await tester.tap(find.text('Rescan'));
    await tester.pumpAndSettle();

    expect(find.textContaining('No agents'), findsOneWidget);
  });

  testWidgets('a second run reports the agent it newly found', (tester) async {
    db.server.agentWork.onRepair = (_) =>
        AgentPathRepairReport(checkedAt: testTime, scan: report(found: 1));
    await pump(tester);
    await tester.tap(find.text('Rescan'));
    await tester.pumpAndSettle();

    db.server.agentWork.onRepair = (_) => AgentPathRepairReport(
      checkedAt: testTime,
      scan: report(found: 2, added: 1),
    );
    await tester.tap(find.text('Rescan'));
    await tester.pumpAndSettle();

    expect(find.textContaining('2 agents'), findsOneWidget);
    expect(find.textContaining('1 new'), findsOneWidget);
  });
}
