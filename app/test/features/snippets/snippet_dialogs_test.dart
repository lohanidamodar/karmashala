import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/snippets/application/snippet_providers.dart';
import 'package:karmashala/src/features/snippets/domain/command_snippet.dart';
import 'package:karmashala/src/features/snippets/presentation/snippet_dialogs.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';
import '../terminal/fake_instance.dart';

/// Where a snippet is written down, and the two things about that form that are
/// safety rather than taste: **submit starts off**, and a pasted multi-line
/// command cannot smuggle one in.
void main() {
  late FakeDataServer server;
  late Override data;
  late ProviderContainer container;

  setUp(() async {
    server = FakeDataServer(clock: () => testTime);
    data = await server.override();
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(data: data),
        clockProvider.overrideWithValue(FixedClock(testTime)),
      ],
    );
  });
  tearDown(() => container.dispose());

  Widget host(Widget Function(BuildContext context) onTap) =>
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => onTap(context),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

  Future<void> openEditor(WidgetTester tester) async {
    await tester.pumpWidget(host((_) => const SnippetEditorDialog()));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('a new snippet does not run itself unless asked', (tester) async {
    late SnippetDraft? draft;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async =>
                    draft = await SnippetEditorDialog.show(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Command'),
      'rm -rf build',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(draft!.submit, isFalse);
    expect(draft!.command, 'rm -rf build');
    expect(
      draft!.shellId,
      isNull,
      reason: 'untagged unless the user picks a shell',
    );
    expect(
      draft!.label,
      'rm -rf build',
      reason: 'an unnamed snippet is named by its own command',
    );
  });

  testWidgets('both dialogs wear the house title, with a way out', (
    tester,
  ) async {
    await openEditor(tester);
    expect(
      tester.widget<DesktopDialogTitle>(find.byType(DesktopDialogTitle)).title,
      'New command snippet',
    );
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(SnippetEditorDialog), findsNothing);

    await tester.pumpWidget(host((_) => const SnippetLibraryDialog()));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<DesktopDialogTitle>(find.byType(DesktopDialogTitle)).title,
      'Command snippets',
    );
  });

  testWidgets('the shell picker offers only shells this machine has', (
    tester,
  ) async {
    // `fakeTerminalOverrides` pins the profile list to PowerShell and Command
    // Prompt, so a WSL option here would mean the form was reading the enum
    // rather than the machine.
    await openEditor(tester);

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();

    expect(find.text('Any shell'), findsWidgets);
    expect(find.text('PowerShell'), findsOneWidget);
    expect(find.text('Command Prompt'), findsOneWidget);
    expect(find.text('WSL'), findsNothing);
  });

  testWidgets('an empty library is the house empty state, at its own height', (
    tester,
  ) async {
    await tester.pumpWidget(host((_) => const SnippetLibraryDialog()));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final empty = find.byType(PanePlaceholder);
    expect(empty, findsOneWidget);
    expect(
      find.descendant(
        of: empty,
        matching: find.textContaining('Nothing saved'),
      ),
      findsOneWidget,
    );
    // A dialog, not a pane: the empty state does not stretch it to the window.
    expect(tester.getSize(empty).height, lessThan(300));
  });

  testWidgets('the library lists what is saved and can remove one', (
    tester,
  ) async {
    container
        .read(commandSnippetsProvider.notifier)
        .add(label: 'Run the tests', command: 'flutter test');

    await tester.pumpWidget(host((_) => const SnippetLibraryDialog()));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Run the tests'), findsOneWidget);
    expect(find.text('Any shell'), findsOneWidget);

    // Asks first, as the settings page does, and takes no for an answer.
    await tester.tap(find.byTooltip('Delete Run the tests'));
    await tester.pumpAndSettle();
    expect(find.text('Delete Run the tests?'), findsOneWidget);
    expect(container.read(commandSnippetsProvider), hasLength(1));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(container.read(commandSnippetsProvider), hasLength(1));

    await tester.tap(find.byTooltip('Delete Run the tests'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(DestructiveButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(container.read(commandSnippetsProvider), isEmpty);
    expect(find.textContaining('Nothing saved yet'), findsOneWidget);
  });

  testWidgets('both dialogs survive the window matrix', (tester) async {
    server.snippetRows.insert(
      CommandSnippet(
        id: 'sn1',
        label: 'Run the tests on this machine only, excluding the live ones',
        command:
            'flutter test --exclude-tags=live-ssh,live-wsl --concurrency=4',
        submit: true,
        createdAt: testTime,
        updatedAt: testTime,
      ),
    );

    for (final (name, dialog) in <(String, Widget)>[
      ('the editor', const SnippetEditorDialog()),
      ('the library', const SnippetLibraryDialog()),
    ]) {
      await expectSurvivesWindowMatrix(
        tester,
        because: name,
        build: () {
          final scope = ProviderContainer(
            overrides: [
              ...fakeTerminalOverrides(data: data),
              clockProvider.overrideWithValue(FixedClock(testTime)),
            ],
          );
          addTearDown(scope.dispose);
          return UncontrolledProviderScope(
            container: scope,
            child: MaterialApp(
              home: Scaffold(body: Center(child: dialog)),
            ),
          );
        },
      );
    }
  });
}
