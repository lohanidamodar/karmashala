import 'dart:io' show SocketException;

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_latest_versions_controller.dart';
import 'package:karmashala/src/features/agents/data/agent_latest_version_fetcher.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/presentation/acp_builtin_agent_row.dart'
    show AcpAgentDetails, acpAgentsNote;
import 'package:karmashala/src/features/settings/presentation/agents_and_accounts_page.dart';
import 'package:karmashala/src/features/settings/presentation/environment_chips.dart';
import 'package:karmashala/src/features/settings/presentation/settings_catalog.dart';
import 'package:karmashala/src/features/settings/presentation/settings_page_body.dart';
import 'package:karmashala/src/features/settings/presentation/terminal_agent_row.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fake_http_client.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../../support/window_matrix.dart';

/// Settings → Agents and accounts, grouped: a header strip with the counts,
/// terminal agents as cards that open, the shipped ACP agents as one line
/// each, the person's own ACP agents with Edit and Remove, and what spans
/// them at the end. Grouping is by what an adapter can do, never by its id.
void main() {
  late TestMachine db;

  /// A terminal agent's descriptor id, taken from the registry by capability
  /// so this test names none.
  late String terminalId;

  /// [terminalId]'s chat form.
  late String chatFormId;

  /// A shipped agent that is a chat alone, run through npx.
  late String npxAcpId;

  setUp(() {
    db = TestMachine();
    FakeDataServer().runsOn(db);
    db.server.environmentRows
      ..upsert(windowsEnv())
      ..upsert(wslEnv());
    final registry = AgentRegistry.builtIn;
    terminalId = registry.folded.firstWhere((f) => f.hasBoth).terminalId!;
    chatFormId = registry.formsOf(terminalId).chatId!;
    npxAcpId = registry.adapters
        .firstWhere(
          (a) =>
              a.acp?.npxPackage != null && registry.foldedIdOf(a.id) == a.id,
        )
        .id;
  });

  /// Claude-shaped: one terminal agent on two machines and its chat form on
  /// the same binary, one shipped chat-alone agent through npx, and one row
  /// a person added, found on Windows.
  void seedInstalls() {
    db.server.installationRows
      ..insert(agentInstallation(id: 'a1', agentId: terminalId))
      ..insert(
        agentInstallation(id: 'a4', agentId: chatFormId, version: null),
      )
      ..insert(
        agentInstallation(
          id: 'a2',
          agentId: terminalId,
          environmentId: 'wsl:Ubuntu',
          path: '/usr/bin/claude',
          version: '1.0.0',
        ),
      )
      ..insert(
        AgentInstallation(
          id: 'a3',
          agentId: npxAcpId,
          executable: const EnvironmentPath(
            environmentId: 'windows',
            path: r'C:\npm\npx.cmd',
          ),
          leadingArguments: [
            '-y',
            AgentRegistry.builtIn.byId(npxAcpId)!.acp!.npxPackage!,
          ],
          createdAt: testTime,
        ),
      );
  }

  AcpAgentRow userRow() => AcpAgentRow(
    id: 'r1',
    name: 'Mine',
    command: 'mine',
    args: const ['--acp'],
    createdAt: testTime,
  );

  Future<List<Override>> overrides() async => [
    await db.server.override(),
    clockProvider.overrideWithValue(FixedClock(testTime)),
    commandRunnerFactoryProvider.overrideWithValue(FakeCommandRunnerFactory()),
    // No registry on the network: a failed check is quiet on the page.
    agentLatestVersionFetcherProvider.overrideWithValue(
      AgentLatestVersionFetcher(
        newClient: () =>
            FakeHttpClient()..throwOnRequest = const SocketException('offline'),
      ),
    ),
  ];

  Widget page(List<Override> scope, {SettingsAnchor? revealing}) =>
      ProviderScope(
        overrides: scope,
        child: MaterialApp(
          home: Scaffold(
            body: SettingsAnchorScope(
              keys: {},
              revealing: revealing,
              child: const SingleChildScrollView(
                child: AgentsAndAccountsBody(),
              ),
            ),
          ),
        ),
      );

  Future<void> pump(WidgetTester tester, {SettingsAnchor? revealing}) async {
    await tester.pumpWidget(page(await overrides(), revealing: revealing));
    await tester.pumpAndSettle();
  }

  Finder expandButton(String name) => find.byTooltip('Expand $name');

  String nameOf(String id) => AgentRegistry.builtIn.displayNameFor(id);

  testWidgets('the header counts agents, installs and machines, and each '
      'group carries its count', (tester) async {
    seedInstalls();
    db.server.acpAgentRows.insert(userRow());
    await pump(tester);

    expect(find.text('DEFAULTS'), findsOneWidget);
    // Claude Code with its chat form counted once, and the npx agent.
    expect(find.text('5 agents · 2 installed on 2 machines'), findsOneWidget);
    expect(find.text('Discover agents'), findsOneWidget);
    expect(find.text('Agent for new sessions'), findsOneWidget);
    expect(find.text('AGENTS · 3'), findsOneWidget);
    expect(find.text('ACP AGENTS (BUILT-IN) · 1'), findsOneWidget);
    expect(find.text('YOUR ACP AGENTS · 1'), findsOneWidget);
    expect(find.text('USAGE AND MAINTENANCE'), findsOneWidget);
    expect(find.text('USAGE & LIMITS'), findsOneWidget);
    expect(find.text('AGENT UPDATES'), findsOneWidget);
    expect(find.text('FIND AGENTS'), findsOneWidget);
  });

  testWidgets('a terminal agent folds to its machines and version, and opens '
      'to its sections', (tester) async {
    seedInstalls();
    await pump(tester);
    final name = nameOf(terminalId);
    final heading = '$name · machines'.toUpperCase();

    final row = find.byWidgetPredicate(
      (w) => w is TerminalAgentRow && w.descriptor.id == terminalId,
    );
    expect(
      find.descendant(
        of: row,
        matching: find.widgetWithText(SettingsChip, 'Windows'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.descendant(of: row, matching: find.byType(SettingsChip)),
        matching: find.textContaining('Ubuntu'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('1.0.0 · read'), findsOneWidget);
    expect(find.byTooltip('Installed on 2 machines'), findsOneWidget);
    expect(find.text(heading), findsNothing);

    await tester.tap(expandButton(name));
    await tester.pumpAndSettle();

    expect(find.text(heading), findsOneWidget);
    expect(find.text('$name · executables'.toUpperCase()), findsOneWidget);
    expect(find.text('$name · behaviour'.toUpperCase()), findsOneWidget);
    expect(find.text('Default model'), findsOneWidget);
    expect(find.text('Executable path'), findsNWidgets(2));
    // Its chat form is inside the same card, not an agent of its own.
    expect(find.text('$name · chat'.toUpperCase()), findsOneWidget);
    expect(find.text('New sessions run as'), findsOneWidget);

    await tester.tap(find.byTooltip('Collapse $name'));
    await tester.pumpAndSettle();
    expect(find.text(heading), findsNothing);
  });

  testWidgets('an agent installed nowhere is one line naming its binary', (
    tester,
  ) async {
    await pump(tester);
    final registry = AgentRegistry.builtIn;
    // One line per agent: a chat form is listed inside its agent's folded
    // card, so only each agent's own form says it here.
    final lines = <String, int>{};
    for (final forms in registry.folded) {
      final adapter = registry.adapterFor(forms.agentId)!;
      final binary = adapter.descriptor.binaries.posix.first;
      // npx is offered only for an agent that ships as an npm package; one
      // the registry ships as an archive is installed from the row instead.
      final npx = adapter.acp?.npxPackage == null ? '' : ', or add it with npx';
      final line =
          'Not installed. Install `$binary` on a machine Karmashala reaches'
          '$npx.';
      lines[line] = (lines[line] ?? 0) + 1;
    }
    for (final MapEntry(key: line, value: count) in lines.entries) {
      expect(find.text(line), findsNWidgets(count), reason: line);
    }
    expect(
      find.byTooltip('Not installed on any machine'),
      findsNWidgets(registry.folded.length),
    );
    // A folded card of a missing agent still opens: its behaviour and saved
    // accounts are settings whether or not it is installed today.
    await tester.tap(expandButton(nameOf(terminalId)));
    await tester.pumpAndSettle();
    expect(find.text('Not installed on any machine'), findsOneWidget);
  });

  testWidgets('a shipped ACP agent shows how it launches and none of a '
      'terminal agent\'s blocks', (tester) async {
    seedInstalls();
    await pump(tester);
    final package = AgentRegistry.builtIn.byId(npxAcpId)!.acp!.npxPackage;

    // A chat alone is one line of its own.
    expect(find.text('npx -y $package'), findsOneWidget);
    expect(expandButton(nameOf(npxAcpId)), findsNothing);
    // Run from its package: npx's own version is never the agent's.
    expect(find.text('via npx · downloaded on first start'), findsOneWidget);
    expect(find.text('Account not read yet'), findsNothing);
    expect(
      find.text('${nameOf(npxAcpId)} · machines'.toUpperCase()),
      findsNothing,
    );
    expect(find.text(acpAgentsNote), findsOneWidget);

    // A chat form of a terminal agent is shown inside that agent's card.
    Finder chatLaunch() => find.descendant(
      of: find.byType(AcpAgentDetails),
      matching: find.text(r'C:\Users\me\.bin\claude.exe'),
    );
    expect(chatLaunch(), findsNothing);
    await tester.tap(expandButton(nameOf(terminalId)));
    await tester.pumpAndSettle();
    // The same binary as its terminal form.
    expect(chatLaunch(), findsOneWidget);
    expect(find.text(acpAgentsNote), findsNWidgets(2));
  });

  testWidgets('an ACP agent\'s version, once read over the protocol, shows '
      'with its age like a terminal agent\'s', (tester) async {
    final row = userRow();
    db.server.acpAgentRows.insert(row);
    db.server.installationRows
      ..insert(
        AgentInstallation(
          id: 'a3',
          agentId: npxAcpId,
          executable: const EnvironmentPath(
            environmentId: 'windows',
            path: r'C:\npm\npx.cmd',
          ),
          leadingArguments: const ['-y', 'pkg'],
          version: '0.9.0',
          versionReadAt: testTime,
          createdAt: testTime,
        ),
      )
      ..insert(
        AgentInstallation(
          id: 'a9',
          agentId: row.agentId,
          executable: const EnvironmentPath(
            environmentId: 'windows',
            path: r'C:\tools\mine.exe',
          ),
          version: '1.0.91',
          versionReadAt: testTime,
          createdAt: testTime,
        ),
      );
    await pump(tester);

    expect(find.textContaining('0.9.0 · read'), findsOneWidget);
    expect(find.textContaining('1.0.91 · read'), findsOneWidget);
    expect(find.text('via npx · downloaded on first start'), findsNothing);
    expect(find.text('version not read'), findsNothing);
  });

  testWidgets('a person\'s ACP agent keeps Edit and Remove, and shows where '
      'it was found', (tester) async {
    final row = userRow();
    db.server.acpAgentRows.insert(row);
    db.server.installationRows.insert(
      AgentInstallation(
        id: 'a9',
        agentId: row.agentId,
        executable: const EnvironmentPath(
          environmentId: 'windows',
          path: r'C:\tools\mine.exe',
        ),
        createdAt: testTime,
      ),
    );
    await pump(tester);

    expect(find.text('Mine'), findsOneWidget);
    expect(find.text('mine --acp'), findsOneWidget);
    expect(find.text('version not read'), findsOneWidget);
    expect(find.widgetWithText(SettingsChip, 'Custom'), findsOneWidget);
    expect(find.widgetWithText(SettingsChip, 'Windows'), findsOneWidget);
    expect(find.byTooltip('Edit Mine'), findsOneWidget);
    expect(find.byTooltip('Remove Mine'), findsOneWidget);
    expect(find.text('Add ACP agent…'), findsOneWidget);
    expect(expandButton('Mine'), findsNothing);
  });

  testWidgets('a deep link to an anchor inside a card opens the card', (
    tester,
  ) async {
    seedInstalls();
    await pump(tester, revealing: SettingsAnchor.claudeAccounts);

    expect(find.text(SettingsAnchor.claudeAccounts.heading), findsOneWidget);
    expect(
      find.text(SettingsAnchor.codexAccounts.heading),
      findsNothing,
      reason: 'the other cards stay folded',
    );
  });

  testWidgets('a group folds and opens again', (tester) async {
    await pump(tester);
    await tester.tap(find.byTooltip('Collapse Agents'));
    await tester.pumpAndSettle();
    expect(expandButton(nameOf(terminalId)), findsNothing);
    await tester.tap(find.byTooltip('Expand Agents'));
    await tester.pumpAndSettle();
    expect(expandButton(nameOf(terminalId)), findsOneWidget);
  });

  testWidgets('an agent with a chat form sets how its new sessions run, '
      'Terminal until changed; a chat-only agent has no such choice', (
    tester,
  ) async {
    seedInstalls();
    await pump(tester);
    // A chat-only agent is one line: nothing to choose.
    expect(find.byType(SegmentedButton<AgentRunForm>), findsNothing);
    final chatFormed = terminalId;
    await tester.tap(expandButton(nameOf(chatFormed)));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AgentsAndAccountsBody)),
    );
    final choice = find.byKey(ValueKey('run-form:$chatFormed'));
    expect(
      tester.widget<SegmentedButton<AgentRunForm>>(choice).selected,
      {AgentRunForm.terminal},
    );
    await tester.ensureVisible(choice);
    await tester.tap(find.descendant(of: choice, matching: find.text('Chat')));
    await tester.pumpAndSettle();
    expect(
      container.read(settingsControllerProvider).runFormFor(chatFormed),
      AgentRunForm.chat,
    );
  });

  testWidgets('what a session hears of a session it starts is chosen here, '
      'a final report until changed', (tester) async {
    await pump(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AgentsAndAccountsBody)),
    );
    final choice = find.byKey(const ValueKey('child-report-mode'));
    await tester.ensureVisible(choice);
    expect(
      tester.widget<SegmentedButton<String>>(choice).selected,
      {'final'},
    );
    await tester.tap(
      find.descendant(of: choice, matching: find.text('Every turn')),
    );
    await tester.pumpAndSettle();
    expect(
      container.read(settingsControllerProvider).childReportMode,
      'each_turn',
    );
  });

  const phone = WindowCell('390x844 (phone)', Size(390, 844));
  const cells = [phone, minimumWindow, desktopWindow, minimumWindowLargeText];

  testWidgets('the page fits every window, folded and with a card open', (
    tester,
  ) async {
    seedInstalls();
    db.server.acpAgentRows.insert(userRow());
    final scope = await overrides();
    await expectSurvivesWindowMatrix(
      tester,
      matrix: cells,
      because: 'chips wrap under the name and cards stack on a phone',
      build: () => page(scope),
      warmUp: (tester) async {
        await tester.tap(expandButton(nameOf(terminalId)));
        await tester.pumpAndSettle();
        expect(
          find.text('${nameOf(terminalId)} · machines'.toUpperCase()),
          findsOneWidget,
        );
      },
    );
  });
}
