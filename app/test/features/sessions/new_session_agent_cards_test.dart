import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:agent_cli/usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/application/agent_usage_providers.dart';
import 'package:karmashala/src/features/agents/presentation/agent_logo.dart';
import 'package:karmashala/src/features/agents/presentation/acp_usage_note.dart';
import 'package:karmashala/src/features/sessions/presentation/new_session_agent_cards.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

/// The agent cards' second line: the machine, and the version when one was
/// read. An agent discovery could only run from its package through npx says
/// so — npx's own version is never shown as the agent's — until the agent
/// has reported its own.
void main() {
  late TestMachine db;
  late String npxAcpId;

  setUp(() {
    db = TestMachine();
    FakeDataServer().runsOn(db);
    db.server.environmentRows.upsert(windowsEnv());
    npxAcpId = AgentRegistry.builtIn.adapters
        .firstWhere((a) => a.acp?.npxPackage != null)
        .id;
  });

  AgentInstallation viaNpx({String? version}) => AgentInstallation(
    id: 'npx',
    agentId: npxAcpId,
    executable: const EnvironmentPath(
      environmentId: 'windows',
      path: r'C:\npm\npx.cmd',
    ),
    leadingArguments: const ['-y', 'pkg'],
    version: version,
    versionReadAt: version == null ? null : testTime,
    createdAt: testTime,
  );

  Future<void> pump(
    WidgetTester tester,
    List<AgentInstallation> installations,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          await db.server.override(),
          agentUsageProvider.overrideWith(
            (ref, installation) => const AsyncLoading<AgentUsage>(),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: NewSessionAgentCards(
              installations: installations,
              selected: null,
              onSelected: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('an npx fallback says so instead of a version', (tester) async {
    await pump(tester, [agentInstallation(), viaNpx()]);
    // Each card wears its agent's mark beside the name.
    expect(find.byType(AgentLogo), findsNWidgets(2));
    expect(find.text('Windows · 1.0.0'), findsOneWidget);
    expect(
      find.text('Windows · via npx · downloaded on first start'),
      findsOneWidget,
    );
  });

  testWidgets('once the agent reported its own version, that is shown', (
    tester,
  ) async {
    await pump(tester, [viaNpx(version: '0.9.0')]);
    expect(find.text('Windows · 0.9.0'), findsOneWidget);
    expect(find.textContaining('via npx'), findsNothing);
  });

  testWidgets('a binary with no reading shows only its machine', (
    tester,
  ) async {
    await pump(tester, [agentInstallation(version: null)]);
    expect(find.text('Windows'), findsOneWidget);
  });

  testWidgets('an ACP agent says limits are not reported, never checks', (
    tester,
  ) async {
    // Every ACP adapter, decided by its capability and not its id.
    final acp = AgentRegistry.builtIn.adapters
        .where((a) => a.acp != null)
        .map((a) => a.id)
        .toList();
    await pump(tester, [
      agentInstallation(),
      for (final id in acp) agentInstallation(id: 'i-$id', agentId: id),
    ]);
    expect(find.text('Checking usage…'), findsOneWidget);
    expect(find.text(kAcpUsageLimitsNote), findsNWidgets(acp.length));
  });
}
