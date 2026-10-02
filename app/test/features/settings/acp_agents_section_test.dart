import 'dart:io' show SocketException;

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart' show AgentDiscoveryReport;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/agents/application/acp_agent_providers.dart';
import 'package:karmashala/src/features/settings/presentation/acp_agent_dialog.dart';
import 'package:karmashala/src/features/settings/presentation/acp_agents_section.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fake_http_client.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../../support/window_matrix.dart';

/// Settings → Agents → ACP agents: the rows a person added, the dialog that
/// adds one from the registry or by hand, and the edit and remove paths.
/// The registry is a canned HTTP answer and the rows live on the fake server.
void main() {
  const registryJson = '''
{"agents": [
  {"id": "gemini", "name": "Gemini CLI", "version": "0.9.0",
   "distribution": {"npx": {"package": "@google/gemini-cli@0.9.0",
                            "args": ["--experimental-acp"]}}},
  {"id": "native", "name": "Native Agent", "version": "1.0.0",
   "distribution": {"binary": {"darwin-aarch64": {"archive": "x.tar.gz",
                                                   "cmd": "native-agent",
                                                   "args": ["--stdio"]}}}}
]}''';

  late TestMachine db;
  late FakeHttpClient http;
  var detections = 0;

  AcpAgentRow row({
    String id = 'r1',
    String name = 'Mine',
    AcpAgentSource source = AcpAgentSource.custom,
  }) => AcpAgentRow(
    id: id,
    name: name,
    command: 'mine',
    args: const ['--acp'],
    env: const {'A': '1'},
    source: source,
    registryId: source == AcpAgentSource.registry ? 'mine' : null,
    createdAt: testTime,
  );

  setUp(() {
    db = TestMachine();
    FakeDataServer().runsOn(db);
    db.server.environmentRows.upsert(windowsEnv());
    detections = 0;
    db.server.agentWork.onDetect = (_) {
      detections++;
      return const AgentDiscoveryReport.empty();
    };
    http = FakeHttpClient(body: registryJson);
  });

  Future<List<Override>> overrides() async => [
    await db.server.override(),
    acpRegistryHttpClientProvider.overrideWithValue(() => http),
    acpRegistryPlatformProvider.overrideWithValue('windows-x86_64'),
    commandRunnerFactoryProvider.overrideWithValue(FakeCommandRunnerFactory()),
  ];

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: await overrides(),
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: AcpAgentsSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openDialog(WidgetTester tester) async {
    await tester.tap(find.text('Add ACP agent…'));
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, String label, String text) async {
    await tester.enterText(find.widgetWithText(TextField, label).first, text);
    await tester.pump();
  }

  testWidgets('with no rows it says so and offers the button', (tester) async {
    await pump(tester);
    expect(find.textContaining('No ACP agents added'), findsOneWidget);
    expect(find.text('Add ACP agent…'), findsOneWidget);
  });

  testWidgets('lists each row with its command and where it came from', (
    tester,
  ) async {
    db.server.acpAgentRows
      ..insert(row())
      ..insert(row(id: 'r2', name: 'Theirs', source: AcpAgentSource.registry));
    await pump(tester);
    expect(find.text('Mine'), findsOneWidget);
    expect(find.text('Theirs'), findsOneWidget);
    expect(find.text('mine --acp'), findsNWidgets(2));
    expect(find.text('Custom'), findsOneWidget);
    expect(find.text('Registry'), findsOneWidget);
  });

  testWidgets(
    'the registry tab lists the fetched entries with this machine\'s launch, '
    'and Add keeps a registry-sourced row and looks for it once',
    (tester) async {
      await pump(tester);
      await openDialog(tester);

      expect(http.requestedUrls, [Uri.parse(AcpRegistryCatalog.registryUrl)]);
      expect(find.text('Gemini CLI'), findsOneWidget);
      expect(
        find.text('0.9.0 · npx -y @google/gemini-cli@0.9.0 --experimental-acp'),
        findsOneWidget,
      );
      // A darwin-only binary on a Windows machine: listed, not pickable.
      expect(find.text('1.0.0 · no build for this machine'), findsOneWidget);
      expect(
        tester
            .widget<ListTile>(find.widgetWithText(ListTile, 'Native Agent'))
            .enabled,
        isFalse,
      );
      final add = find.widgetWithText(FilledButton, 'Add');
      expect(tester.widget<FilledButton>(add).onPressed, isNull);

      // The filter narrows by name.
      await tester.enterText(
        find.widgetWithText(TextField, 'Filter agents'),
        'nat',
      );
      await tester.pumpAndSettle();
      expect(find.text('Gemini CLI'), findsNothing);
      await tester.enterText(
        find.widgetWithText(TextField, 'Filter agents'),
        '',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Gemini CLI'));
      await tester.pumpAndSettle();
      await tester.tap(add);
      await tester.pumpAndSettle();

      final kept = db.server.acpAgentRows.getAll().single;
      expect(kept.name, 'Gemini CLI');
      expect(kept.command, 'npx');
      expect(kept.args, [
        '-y',
        '@google/gemini-cli@0.9.0',
        '--experimental-acp',
      ]);
      expect(kept.env, isEmpty);
      expect(kept.source, AcpAgentSource.registry);
      expect(kept.registryId, 'gemini');
      expect(detections, 1);
      expect(find.byType(AcpAgentDialog), findsNothing);
      expect(find.text('Gemini CLI'), findsOneWidget);
    },
  );

  testWidgets('a registry that cannot be fetched says so; Custom still works', (
    tester,
  ) async {
    http.throwOnRequest = const SocketException('no route to host');
    await pump(tester);
    await openDialog(tester);

    expect(find.textContaining('could not be fetched'), findsOneWidget);
    expect(find.textContaining('no connection'), findsOneWidget);

    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();
    await type(tester, 'Name', 'Local');
    await type(tester, 'Command', 'local-agent');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    final kept = db.server.acpAgentRows.getAll().single;
    expect(kept.name, 'Local');
    expect(kept.command, 'local-agent');
    expect(kept.source, AcpAgentSource.custom);
  });

  testWidgets('Custom refuses a blank name, a blank command and a bad '
      'environment line in words, and keeps nothing', (tester) async {
    await pump(tester);
    await openDialog(tester);
    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(find.text('Give the agent a name.'), findsOneWidget);

    await type(tester, 'Name', 'Local');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(find.text('Say which command runs it.'), findsOneWidget);

    await type(tester, 'Command', 'local-agent');
    await type(tester, 'Environment', 'BROKEN');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(find.text('Environment line 1 needs KEY=value.'), findsOneWidget);

    expect(db.server.acpAgentRows.getAll(), isEmpty);
    expect(find.byType(AcpAgentDialog), findsOneWidget);
  });

  testWidgets('Custom splits the arguments and parses the environment', (
    tester,
  ) async {
    await pump(tester);
    await openDialog(tester);
    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();

    await type(tester, 'Name', 'Local');
    await type(tester, 'Command', r'C:\tools\local agent.exe');
    await type(tester, 'Arguments', '--acp "two words" --level=3');
    await type(tester, 'Environment', 'A=1\nB=x=y');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    final kept = db.server.acpAgentRows.getAll().single;
    expect(kept.command, r'C:\tools\local agent.exe');
    expect(kept.args, ['--acp', 'two words', '--level=3']);
    expect(kept.env, {'A': '1', 'B': 'x=y'});
    expect(kept.source, AcpAgentSource.custom);
    expect(detections, 1);
  });

  testWidgets('Edit opens the form prefilled and Save rewrites the row', (
    tester,
  ) async {
    db.server.acpAgentRows.insert(row(source: AcpAgentSource.registry));
    await pump(tester);
    await tester.tap(find.byTooltip('Edit Mine'));
    await tester.pumpAndSettle();

    expect(find.text('Edit Mine'), findsOneWidget);
    // No origin switch when editing: the form is the only thing to edit.
    expect(find.text('From registry'), findsNothing);
    String value(String label) => tester
        .widget<TextField>(find.widgetWithText(TextField, label))
        .controller!
        .text;
    expect(value('Name'), 'Mine');
    expect(value('Command'), 'mine');
    expect(value('Arguments'), '--acp');
    expect(value('Environment'), 'A=1');

    await type(tester, 'Name', 'Renamed');
    await type(tester, 'Arguments', '--acp --verbose');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final kept = db.server.acpAgentRows.getAll().single;
    expect(kept.id, 'r1');
    expect(kept.name, 'Renamed');
    expect(kept.args, ['--acp', '--verbose']);
    // A registry row edited stays a registry row.
    expect(kept.source, AcpAgentSource.registry);
    expect(kept.registryId, 'mine');
    // An edit is not a new agent: nothing to discover.
    expect(detections, 0);
    expect(find.text('Renamed'), findsOneWidget);
  });

  testWidgets('Remove asks first, and Cancel keeps the row', (tester) async {
    db.server.acpAgentRows.insert(row());
    await pump(tester);

    await tester.tap(find.byTooltip('Remove Mine'));
    await tester.pumpAndSettle();
    expect(find.text('Remove Mine?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(db.server.acpAgentRows.getAll(), hasLength(1));

    await tester.tap(find.byTooltip('Remove Mine'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(db.server.acpAgentRows.getAll(), isEmpty);
    expect(find.text('Mine'), findsNothing);
    expect(find.textContaining('No ACP agents added'), findsOneWidget);
  });

  const phone = WindowCell('390x844 (phone)', Size(390, 844));
  const cells = [phone, minimumWindow, desktopWindow, minimumWindowLargeText];

  testWidgets('the registry tab fits every window', (tester) async {
    final scope = await overrides();
    await expectSurvivesWindowMatrix(
      tester,
      matrix: cells,
      because: 'a filter, a list and a note stacked in one dialog',
      build: () => ProviderScope(
        overrides: scope,
        child: const MaterialApp(home: AcpAgentDialog()),
      ),
      warmUp: (tester) async {
        expect(find.text('Gemini CLI'), findsOneWidget);
      },
    );
  });

  testWidgets('the custom form fits every window, refusal included', (
    tester,
  ) async {
    final scope = await overrides();
    await expectSurvivesWindowMatrix(
      tester,
      matrix: cells,
      because: 'four fields and a refusal banner above them',
      build: () => ProviderScope(
        overrides: scope,
        child: const MaterialApp(home: AcpAgentDialog()),
      ),
      warmUp: (tester) async {
        await tester.tap(find.text('Custom'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Add'));
        await tester.pumpAndSettle();
        expect(find.text('Give the agent a name.'), findsOneWidget);
      },
    );
  });
}
