import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:agent_cli/usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/presentation/acp_usage_note.dart';
import 'package:karmashala/src/features/settings/presentation/acp_builtin_agent_row.dart';
import 'package:karmashala/src/features/settings/presentation/agent_usage_section.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show AccountUsageState;

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

void main() {
  group('describeAgentLaunch', () {
    test('formats npx rows, CLI subcommands, and direct binaries distinctly', () {
      final npx = AgentInstallation(
        id: 'g1',
        agentId: AgentIds.grok,
        executable: const EnvironmentPath(
          environmentId: 'windows',
          path: r'C:\Program Files\nodejs\npx.cmd',
        ),
        leadingArguments: const ['-y', '@xai-official/grok'],
        createdAt: testTime,
      );
      expect(describeAgentLaunch(npx), 'npx -y @xai-official/grok');

      final agySubcommand = AgentInstallation(
        id: 'a1',
        agentId: AgentIds.antigravityAcp,
        executable: const EnvironmentPath(
          environmentId: 'wsl:archlinux',
          path: '/home/u/.local/bin/agy',
        ),
        leadingArguments: const ['acp'],
        createdAt: testTime,
      );
      expect(describeAgentLaunch(agySubcommand), '/home/u/.local/bin/agy acp');

      final direct = AgentInstallation(
        id: 'a2',
        agentId: AgentIds.antigravityAcp,
        executable: const EnvironmentPath(
          environmentId: 'windows',
          path: r'C:\acp\agy_acp_server.exe',
        ),
        createdAt: testTime,
      );
      expect(describeAgentLaunch(direct), r'C:\acp\agy_acp_server.exe');
    });
  });

  testWidgets('UsageSection reads usage for ACP adapters with a usage endpoint '
      'and shows the ACP note for those without', (tester) async {
    final db = TestMachine();
    FakeDataServer().runsOn(db);
    db.server.environmentRows.upsert(windowsEnv());
    final agyChat = agentInstallation(
      id: 'agy-chat',
      agentId: AgentIds.antigravityAcp,
      path: r'C:\acp\agy_acp_server.exe',
    );
    final grok = agentInstallation(
      id: 'grok-1',
      agentId: AgentIds.grok,
      path: r'C:\bin\grok.cmd',
    );
    db.server.agentWork.onRefresh = (key) => AccountUsageState(
      accountKey: key,
      agentId: agyChat.agentId,
      environmentId: agyChat.environmentId,
      usage: AgentUsage(
        fetchedAt: testTime,
        email: 'dev@example.com',
        windows: [
          UsageWindow(
            label: 'Gemini · 5-hour',
            percent: 35,
            span: kUsageFiveHourWindow,
            resetsAt: testTime.add(const Duration(hours: 3)),
          ),
        ],
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          await db.server.override(),
          clockProvider.overrideWithValue(MovableClock(testTime)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: UsageSection(installations: [agyChat, grok]),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // Grok has no usage endpoint -> shows ACP limits note.
    expect(find.textContaining(kAcpUsageLimitsNote), findsOneWidget);
    // Antigravity · Chat has a usage endpoint -> offers Check usage and reads it.
    expect(find.text('Check usage'), findsOneWidget);

    await tester.tap(find.text('Check usage'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Gemini · 5-hour'), findsOneWidget);
    expect(find.textContaining('35%'), findsOneWidget);
    expect(find.text('dev@example.com'), findsOneWidget);
  });
}
