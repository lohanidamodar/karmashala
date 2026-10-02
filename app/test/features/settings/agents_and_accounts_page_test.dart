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
import 'package:karmashala/src/features/settings/presentation/acp_builtin_agent_row.dart'
    show acpAgentsNote;
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
  late String npxAcpId;

  setUp(() {
    db = TestMachine();
    FakeDataServer().runsOn(db);
    db.server.environmentRows
      ..upsert(windowsEnv())
      ..upsert(wslEnv());
    final registry = AgentRegistry.builtIn;
    terminalId = registry.adapters.firstWhere((a) => a.acp == null).id;
    npxAcpId = registry.adapters
        .firstWhere((a) => a.acp?.npxPackage != null)
        .id;
  });

  /// Claude-shaped: one terminal agent on two machines, one shipped ACP agent
  /// through npx, and one row a person added, found on Windows.
  void seedInstalls() {
    db.server.installationRows
      ..insert(agentInstallation(id: 'a1', agentId: terminalId))
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
    expect(find.text('8 agents · 2 installed on 2 machines'), findsOneWidget);
    expect(find.text('Discover agents'), findsOneWidget);
    expect(find.text('Agent for new sessions'), findsOneWidget);
    expect(find.text('TERMINAL AGENTS · 3'), findsOneWidget);
    expect(find.text('ACP AGENTS (BUILT-IN) · 4'), findsOneWidget);
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

    await tester.tap(find.byTooltip('Collapse $name'));
    await tester.pumpAndSettle();
    expect(find.text(heading), findsNothing);
  });

  testWidgets('an agent installed nowhere is one line naming its binary', (
    tester,
  ) async {
    await pump(tester);
    final registry = AgentRegistry.builtIn;
    final terminal = registry.adapters.where((a) => a.acp == null);
    final acp = registry.adapters.where((a) => a.acp != null);

    for (final adapter in terminal) {
      final binary = adapter.descriptor.binaries.posix.first;
      expect(
        find.text(
          'Not installed. Install `$binary` on a machine Karmashala reaches.',
        ),
        findsOneWidget,
      );
    }
    for (final adapter in acp) {
      final binary = adapter.descriptor.binaries.posix.first;
      expect(
        find.text(
          'Not installed. Install `$binary` on a machine Karmashala reaches, '
          'or add it with npx.',
        ),
        findsOneWidget,
      );
    }
    expect(
      find.byTooltip('Not installed on any machine'),
      findsNWidgets(registry.adapters.length),
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

    expect(find.text('npx -y $package'), findsOneWidget);
    expect(expandButton(nameOf(npxAcpId)), findsNothing);
    // Run from its package: npx's own version is never the agent's.
    expect(find.text('via npx · downloaded on first start'), findsOneWidget);
    expect(find.text('version not read'), findsNothing);
    expect(find.text('Account not read yet'), findsNothing);
    expect(
      find.text('${nameOf(npxAcpId)} · machines'.toUpperCase()),
      findsNothing,
    );
    expect(find.text(acpAgentsNote), findsOneWidget);
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
    await tester.tap(find.byTooltip('Collapse Terminal agents'));
    await tester.pumpAndSettle();
    expect(expandButton(nameOf(terminalId)), findsNothing);
    await tester.tap(find.byTooltip('Expand Terminal agents'));
    await tester.pumpAndSettle();
    expect(expandButton(nameOf(terminalId)), findsOneWidget);
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
