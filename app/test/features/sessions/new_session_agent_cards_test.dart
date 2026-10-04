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
    // Not a form of Claude Code, whose card the fixture's own install draws.
    npxAcpId = AgentRegistry.builtIn.adapters
        .firstWhere(
          (a) =>
              a.acp?.npxPackage != null &&
              AgentRegistry.builtIn.foldedIdOf(a.id) != AgentIds.claudeCode,
        )
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
    // Installed only as chat: the forms with no terminal agent installed here.
    final chatOnly = acp
        .where(
          (id) => AgentRegistry.builtIn.foldedIdOf(id) != AgentIds.claudeCode,
        )
        .length;
    await pump(tester, [
      agentInstallation(),
      for (final id in acp) agentInstallation(id: 'i-$id', agentId: id),
    ]);
    // Claude's chat form folds into its terminal card, which reads the
    // account once.
    expect(find.text('Checking usage…'), findsOneWidget);
    expect(find.text(kAcpUsageLimitsNote), findsNWidgets(chatOnly));
  });

  group('an agent with a terminal and a chat form', () {
    AgentInstallation chat() =>
        agentInstallation(id: 'chat', agentId: AgentIds.claudeAcp);

    Future<List<AgentInstallation>> pumpPicking(
      WidgetTester tester,
      List<AgentInstallation> installations, {
      AgentInstallation? selected,
    }) async {
      final picked = <AgentInstallation>[];
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
                selected: selected,
                onSelected: picked.add,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return picked;
    }

    testWidgets('is one card, named once, with a Terminal | Chat choice', (
      tester,
    ) async {
      await pumpPicking(tester, [agentInstallation(), chat()]);
      expect(find.byKey(const ValueKey('agent-card:a1')), findsOneWidget);
      expect(find.byKey(const ValueKey('agent-card:chat')), findsNothing);
      expect(find.text('Claude Code'), findsOneWidget);
      expect(find.text('Claude Code · Chat'), findsNothing);
      expect(find.byKey(const ValueKey('agent-form:a1:terminal')), findsOne);
      expect(find.byKey(const ValueKey('agent-form:a1:chat')), findsOne);
      // Its usage is the account's, read once.
      expect(find.text('Checking usage…'), findsOneWidget);
      expect(find.text(kAcpUsageLimitsNote), findsNothing);
    });

    testWidgets('Chat picks the chat installation and is remembered', (
      tester,
    ) async {
      final picked = await pumpPicking(tester, [agentInstallation(), chat()]);
      await tester.tap(find.byKey(const ValueKey('agent-form:a1:chat')));
      await tester.pumpAndSettle();
      expect(picked.map((i) => i.id), ['chat']);
      // A tap on the card now starts it as a chat, the form last chosen.
      await tester.tap(find.text('Claude Code'));
      await tester.pumpAndSettle();
      expect(picked.map((i) => i.id), ['chat', 'chat']);
    });

    testWidgets('a tap on the form a card already shows still picks that '
        'card', (tester) async {
      // Two cards of one agent: the form is remembered per agent, so the
      // other card already shows Chat when this one was set to it.
      final wsl = agentInstallation(
        id: 'w1',
        environmentId: 'wsl:Ubuntu',
        path: '/home/u/.local/bin/claude',
      );
      final wslChat = agentInstallation(
        id: 'wchat',
        agentId: AgentIds.claudeAcp,
        environmentId: 'wsl:Ubuntu',
        path: '/home/u/.local/bin/claude',
      );
      final installs = [agentInstallation(), chat(), wsl, wslChat];
      final picked = await pumpPicking(tester, installs);
      await tester.tap(find.byKey(const ValueKey('agent-form:a1:chat')));
      await tester.pumpAndSettle();
      expect(picked.map((i) => i.id), ['chat']);
      // The WSL card shows Chat already; Chat on it is still a choice of it.
      await tester.tap(find.byKey(const ValueKey('agent-form:w1:chat')));
      await tester.pumpAndSettle();
      expect(picked.map((i) => i.id), ['chat', 'wchat']);
    });

    testWidgets('a tap on the card picks Terminal until Chat is chosen', (
      tester,
    ) async {
      final picked = await pumpPicking(tester, [agentInstallation(), chat()]);
      await tester.tap(find.text('Claude Code'));
      await tester.pumpAndSettle();
      expect(picked.map((i) => i.id), ['a1']);
    });

    testWidgets('Terminal stays on one line at the dialog\'s width', (
      tester,
    ) async {
      // The dialog is 420 wide and lays cards two across.
      final picked = <AgentInstallation>[];
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
              body: Center(
                child: SizedBox(
                  width: 420,
                  child: NewSessionAgentCards(
                    installations: [agentInstallation(), chat()],
                    selected: null,
                    onSelected: picked.add,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final terminal = find.byKey(const ValueKey('agent-form:a1:terminal'));
      final chatLabel = find.byKey(const ValueKey('agent-form:a1:chat'));
      expect(
        tester.getSize(terminal).height,
        tester.getSize(chatLabel).height,
        reason: 'a wrapped label is two lines tall',
      );
    });

    testWidgets('both forms fit two cards across a phone', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
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
              body: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: NewSessionAgentCards(
                  installations: [
                    agentInstallation(),
                    chat(),
                    agentInstallation(id: 'x', agentId: AgentIds.codex),
                    agentInstallation(id: 'xc', agentId: AgentIds.codexAcp),
                  ],
                  selected: null,
                  onSelected: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(ToggleButtons), findsNWidgets(2));
    });

    testWidgets('the form picked is the one the card shows selected', (
      tester,
    ) async {
      final installs = [agentInstallation(), chat()];
      await pumpPicking(tester, installs, selected: installs.last);
      final choice = tester.widget<ToggleButtons>(find.byType(ToggleButtons));
      expect(choice.isSelected, [false, true]);
    });
  });

  testWidgets('an agent with one form offers no choice', (tester) async {
    await pump(tester, [
      agentInstallation(id: 'x', agentId: AgentIds.codex),
      agentInstallation(id: 'g', agentId: AgentIds.grok),
    ]);
    expect(find.byKey(const ValueKey('agent-card:x')), findsOneWidget);
    expect(find.byKey(const ValueKey('agent-card:g')), findsOneWidget);
    expect(find.byType(ToggleButtons), findsNothing);
  });

  testWidgets('installed only as chat, a paired agent is one card under the '
      'agent\'s name, with no choice', (tester) async {
    await pump(tester, [
      agentInstallation(id: 'cx', agentId: AgentIds.codexAcp),
    ]);
    expect(find.text('Codex CLI'), findsOneWidget);
    expect(find.byType(ToggleButtons), findsNothing);
  });
}
