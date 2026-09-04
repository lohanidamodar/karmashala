import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/agents/application/agent_hook_installation_service.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/settings/presentation/tools_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

/// Whether the app admits, on screen, that it cannot see its agents properly.
///
/// A skipped environment is not a transient error: for the rest of the run,
/// `awaitingApproval` and `failed` are unreportable for every session in it,
/// because no shipped CLI writes them to a transcript worth trusting. The only
/// trace used to be one `I bootstrap:` line, and nine of the owner's sessions
/// ran a whole day on disk probes with nothing on screen saying so.
void main() {
  late AppDatabase db;

  // The environments the ids in these reports refer to. Without them the page
  // can only fall back to the raw id, and the local host's raw id is the
  // literal `windows` on a Mac.
  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db)
      ..upsert(posixEnv())
      ..upsert(wslEnv());
  });
  tearDown(() => db.close());

  Future<void> pump(WidgetTester tester, AgentHookInstallationReport report) {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        agentHookInstallationReportProvider.overrideWith(
          () => _StubReport(report),
        ),
      ],
    );
    addTearDown(container.dispose);
    return tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: McpBridgeSection()),
          ),
        ),
      ),
    );
  }

  testWidgets('a skipped environment is named, with its reason', (
    tester,
  ) async {
    await pump(
      tester,
      const AgentHookInstallationReport([
        AgentHookInstallation(
          agentId: 'claudeCode',
          environmentId: 'wsl:Ubuntu',
          installed: false,
          skippedBecause:
              'the callback address 172.18.240.1:47821 does not answer from '
              'inside this environment',
        ),
      ]),
    );

    expect(find.textContaining('WSL · Ubuntu'), findsOneWidget);
    expect(find.textContaining('172.18.240.1:47821'), findsOneWidget);
    expect(
      find.textContaining('waiting for approval'),
      findsOneWidget,
      reason: 'the cost has to be stated, not just the failure',
    );
  });

  testWidgets('one line per environment, not one per agent', (tester) async {
    await pump(
      tester,
      const AgentHookInstallationReport([
        AgentHookInstallation(
          agentId: 'claudeCode',
          environmentId: 'wsl:Ubuntu',
          installed: false,
          skippedBecause: 'the door does not answer',
        ),
        AgentHookInstallation(
          agentId: 'antigravity',
          environmentId: 'wsl:Ubuntu',
          installed: false,
          skippedBecause: 'the door does not answer',
        ),
      ]),
    );

    expect(find.textContaining('WSL · Ubuntu'), findsOneWidget);
  });

  testWidgets('the local host is named, never keyed', (tester) async {
    // `localHostEnvironmentId` is the literal `windows` on every platform, so
    // this line told a Mac's owner there were "no status callbacks from
    // windows" — about the machine they were sitting at.
    await pump(
      tester,
      const AgentHookInstallationReport([
        AgentHookInstallation(
          agentId: 'claudeCode',
          environmentId: 'windows',
          installed: false,
          skippedBecause: 'the agent is not installed in this environment',
        ),
      ]),
    );

    expect(
      find.textContaining('No status callbacks from macOS'),
      findsOneWidget,
    );
    expect(find.textContaining('from windows'), findsNothing);
  });

  testWidgets('a clean install says nothing at all', (tester) async {
    await pump(
      tester,
      const AgentHookInstallationReport([
        AgentHookInstallation(
          agentId: 'claudeCode',
          environmentId: 'wsl:Ubuntu',
          installed: true,
        ),
      ]),
    );

    expect(find.textContaining('No status callbacks'), findsNothing);
  });
}

class _StubReport extends AgentHookInstallationReportController {
  _StubReport(this._report);

  final AgentHookInstallationReport _report;

  @override
  AgentHookInstallationReport build() => _report;
}
