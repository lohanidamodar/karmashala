import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/explorer/presentation/explorer_panel.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/test_machine.dart';
import '../../support/fake_data_server.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// **A row's menu says each verb once, and a key it names is a key that works.**
///
/// A session's menu listed "Select" twice while an imported conversation's had
/// none, and `F2` stood beside "Rename" as a label only.
void main() {
  late TestMachine db;
  late FakeDataServer server;

  setUp(() {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project(id: 'p1', name: 'Hub', path: r'C:\hub'));
    server.repositoryRows.insert(
      repository(id: 'r1', name: 'hub', path: r'C:\hub'),
    );
    server.installationRows.insert(agentInstallation());
    db.server.sessionRows.insert(
      Session(
        id: 'n0',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Fix login',
        useWorktree: false,
        status: SessionStatus.completed,
        createdAt: testTime,
      ),
    );
    db.server.importedRows.insertIfAbsent(
      ImportedSession(
        id: 'i0',
        repositoryId: 'r1',
        cli: AgentIds.claudeCode,
        externalId: 'cli-i0',
        environmentId: 'windows',
        filePath: r'C:\store\i0.jsonl',
        storeHome: r'C:\store',
        isSubagent: false,
        preview: 'Old chat',
        title: 'Old chat',
        updatedAt: testTime,
        createdAt: testTime,
      ),
    );
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(460, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(machine: db),
        await server.override(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('n-')),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(),
        ),
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
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light().copyWith(platform: TargetPlatform.windows),
          builder: (context, inner) => UiDensity.wrap(context, inner!),
          home: const Scaffold(body: ExplorerPanel()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hub'));
    await tester.pumpAndSettle();
  }

  Future<void> rightClick(WidgetTester tester, String text) async {
    await tester.tap(find.text(text), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
  }

  final menuItems = find.byWidgetPredicate(
    (widget) => widget is DesktopMenuItem<String>,
  );

  /// The words of the open menu, top to bottom — labels and shortcut hints.
  List<String> menuLabels(WidgetTester tester) => [
    for (final text in tester.widgetList<Text>(
      find.descendant(of: menuItems, matching: find.byType(Text)),
    ))
      text.data!,
  ];

  Future<void> focusRow(WidgetTester tester, String text) async {
    Focus.of(tester.element(find.text(text))).requestFocus();
    await tester.pumpAndSettle();
  }

  group('every row menu says each verb once', () {
    for (final (row, kind) in [
      ('Fix login', 'a session'),
      ('Old chat', 'an imported conversation'),
      ('Hub', 'a project'),
    ]) {
      testWidgets('$kind offers Select, once, and nothing twice', (
        tester,
      ) async {
        await pump(tester);
        await rightClick(tester, row);

        final labels = menuLabels(tester);
        expect(labels.where((label) => label == 'Select'), hasLength(1));
        expect(labels.toSet(), hasLength(labels.length), reason: '$labels');
      });
    }

    testWidgets('Select on an imported conversation ticks it', (tester) async {
      await pump(tester);
      await rightClick(tester, 'Old chat');
      await tester.tap(find.text('Select'));
      await tester.pumpAndSettle();

      expect(find.text('1 session selected'), findsOneWidget);
    });
  });

  group('F2 is the key the menu says it is', () {
    testWidgets('renames the focused session', (tester) async {
      await pump(tester);
      await focusRow(tester, 'Fix login');

      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pumpAndSettle();
      expect(find.text('Rename session'), findsOneWidget);

      await tester.enterText(find.byType(TextField).last, 'Fix sign-in');
      await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
      await tester.pumpAndSettle();

      expect(db.server.sessionRows.getById('n0')!.title, 'Fix sign-in');
      expect(find.text('Fix sign-in'), findsOneWidget);
    });

    testWidgets('renames the focused imported conversation', (tester) async {
      await pump(tester);
      await focusRow(tester, 'Old chat');

      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Older chat');
      await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
      await tester.pumpAndSettle();

      expect(db.server.importedRows.getById('i0')!.title, 'Older chat');
    });

    testWidgets('opens Edit project on a focused project, which says so', (
      tester,
    ) async {
      await pump(tester);
      await rightClick(tester, 'Hub');
      expect(
        find.descendant(
          of: find.ancestor(
            of: find.text('Edit project…'),
            matching: menuItems,
          ),
          matching: find.text('F2'),
        ),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      await focusRow(tester, 'Hub');
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pumpAndSettle();
      expect(find.text('Edit project'), findsOneWidget);
    });

    testWidgets('does nothing on a row that has no name to change', (
      tester,
    ) async {
      await pump(tester);
      // The Terminals group, drawn by its machine's name alone (46185a97c).
      await focusRow(tester, 'WINDOWS');
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });
  });
}
