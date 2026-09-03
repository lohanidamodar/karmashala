import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/mcp/snippet_tools.dart';
import 'package:karmashala/src/features/settings/presentation/settings_nav.dart';
import 'package:karmashala/src/features/settings/presentation/settings_screen.dart';
import 'package:karmashala/src/features/snippets/application/snippet_providers.dart';
import 'package:karmashala/src/features/snippets/data/command_snippet_dao.dart';
import 'package:karmashala/src/features/snippets/domain/command_snippet.dart';
import 'package:karmashala/src/features/snippets/presentation/snippet_dialogs.dart';
import 'package:karmashala/src/features/snippets/presentation/snippets_settings_page.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';
import '../terminal/fake_instance.dart';

/// Settings → Snippets: the library's *discoverable* door.
///
/// Two things are worth pinning here. The page has to be reachable by looking
/// for it — the whole complaint was that snippet management lived nowhere but
/// the command palette — and it has to be **live**: a snippet saved anywhere
/// else in the app appears on it without the page being reopened, which is the
/// other half of the same report ("I added one and it didn't show up").
void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = AppDatabase.memory();
    // The settings screen's Terminal page resolves the default shell against
    // the environments, and the nav can reach it from here.
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    db.close();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: SnippetsSettingsPage()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('an empty library says so, and offers the way out of it', (
    tester,
  ) async {
    await pumpPage(tester);

    expect(find.text('COMMAND SNIPPETS'), findsOneWidget);
    expect(find.text('Nothing saved yet.'), findsOneWidget);
    expect(find.text('New snippet'), findsOneWidget);
  });

  testWidgets('a snippet saved anywhere else appears without a remount', (
    tester,
  ) async {
    await pumpPage(tester);
    expect(find.text('Nothing saved yet.'), findsOneWidget);

    // The element the page is mounted on, before the write. If the assertion
    // at the bottom passes on a *different* element, the tree was rebuilt from
    // scratch and this test would prove nothing about watching.
    final before = tester.element(find.byType(SnippetsSettingsPage));

    // Written through the controller, which is exactly what the library
    // dialog, the palette's editor and `snippet_add` all do — no widget of
    // this page is involved.
    container
        .read(commandSnippetsProvider.notifier)
        .add(label: 'Run the tests', command: 'flutter test');

    // One frame. Not `pumpWidget`: nothing is being re-hosted, and a page that
    // only refreshed on a remount is the bug.
    await tester.pump();

    expect(find.text('Run the tests'), findsOneWidget);
    expect(find.text('flutter test'), findsOneWidget);
    expect(find.text('Any shell · typed at the prompt'), findsOneWidget);
    expect(find.text('Nothing saved yet.'), findsNothing);
    expect(
      tester.element(find.byType(SnippetsSettingsPage)),
      same(before),
      reason: 'the same element rebuilt — the page watched rather than being '
          'replaced',
    );
  });

  testWidgets("an agent's snippet_add lands on the open page too", (
    tester,
  ) async {
    await pumpPage(tester);

    // The MCP path, through the tool an agent actually calls, on the same
    // container the page is mounted in.
    await SnippetControlTools(container).call('snippet_add', {
      'label': 'Tail the log',
      'command': 'tail -f /var/log/syslog',
      'shell': 'wsl',
    });
    await tester.pump();

    expect(find.text('Tail the log'), findsOneWidget);
    expect(find.text('WSL · typed at the prompt'), findsOneWidget);
  });

  testWidgets('the page adds, edits and deletes through the same editor', (
    tester,
  ) async {
    await pumpPage(tester);

    // Add.
    await tester.tap(find.text('New snippet'));
    await tester.pumpAndSettle();
    expect(find.byType(SnippetEditorDialog), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Command'),
      'flutter analyze',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(container.read(commandSnippetsProvider), hasLength(1));
    expect(
      find.text('flutter analyze'),
      findsNWidgets(2),
      reason: 'title and command both: an unnamed snippet is named by itself',
    );

    // Edit — the same dialog, opened on the existing snippet.
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Name (optional)'),
      'Analyze',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(container.read(commandSnippetsProvider).single.label, 'Analyze');
    expect(find.text('Analyze'), findsOneWidget);

    // Delete, which asks first and takes no for an answer.
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete Analyze?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(container.read(commandSnippetsProvider), hasLength(1));

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(container.read(commandSnippetsProvider), isEmpty);
    expect(find.text('Nothing saved yet.'), findsOneWidget);
  });

  testWidgets('a snippet that runs itself says so in words', (tester) async {
    container
        .read(commandSnippetsProvider.notifier)
        .add(
          label: 'Clean',
          command: 'flutter clean',
          shellId: 'powerShell',
          submit: true,
        );

    await pumpPage(tester);

    expect(
      find.text('PowerShell · runs as soon as it is picked'),
      findsOneWidget,
    );
  });

  testWidgets('a shell this build cannot resolve is explained, not hidden', (
    tester,
  ) async {
    // Everything that *picks* a snippet filters this one out — it fits no pane
    // by design. The management page is the only place it can be seen at all,
    // which is the point of it being here.
    CommandSnippetDao(db).insert(
      CommandSnippet(
        id: 'sn-future',
        label: 'From a later build',
        command: 'nu -c ls',
        shellId: 'nushell',
        createdAt: testTime,
        updatedAt: testTime,
      ),
    );

    await pumpPage(tester);

    expect(find.text('From a later build'), findsOneWidget);
    expect(
      find.textContaining('offered in no terminal'),
      findsOneWidget,
    );
  });

  testWidgets('Settings has a Snippets section, found by looking for it', (
    tester,
  ) async {
    container
        .read(commandSnippetsProvider.notifier)
        .add(label: 'Run the tests', command: 'flutter test');

    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // The filter is how someone who does not know where it lives finds it.
    await tester.enterText(find.byType(TextField).first, 'snippet');
    await tester.pumpAndSettle();
    expect(find.text('Snippets'), findsOneWidget);
    expect(find.text('Terminal'), findsNothing);

    await tester.tap(find.text('Snippets'));
    await tester.pumpAndSettle();
    expect(find.byType(SnippetsSettingsPage), findsOneWidget);
    expect(find.text('Run the tests'), findsOneWidget);
  });

  testWidgets('the deep link lands on it', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: SettingsScreen(initialSection: SettingsSectionId.snippets),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('COMMAND SNIPPETS'), findsOneWidget);
  });

  testWidgets('the page survives phone and desktop widths', (tester) async {
    CommandSnippetDao(db).insert(
      CommandSnippet(
        id: 'sn-long',
        // Long on purpose: a fixed row would find its overflow here first.
        label: 'Run the tests on this machine only, excluding the live ones',
        command: 'flutter test --exclude-tags=live-ssh,live-wsl --concurrency=4',
        shellId: 'powerShell',
        submit: true,
        createdAt: testTime,
        updatedAt: testTime,
      ),
    );

    await expectSurvivesWindowMatrix(
      tester,
      because: 'Settings → Snippets',
      matrix: const [
        WindowCell('390x844 (phone)', Size(390, 844)),
        desktopWindow,
        minimumWindowLargeText,
      ],
      build: () {
        final scope = ProviderContainer(
          overrides: [
            ...fakeTerminalOverrides(database: db),
            clockProvider.overrideWithValue(FixedClock(testTime)),
          ],
        );
        addTearDown(scope.dispose);
        return UncontrolledProviderScope(
          container: scope,
          child: const MaterialApp(
            home: SettingsScreen(initialSection: SettingsSectionId.snippets),
          ),
        );
      },
    );
  });
}
