import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/app/shell/shell_shortcuts.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/notes/application/notes_providers.dart';
import 'package:karmashala/src/features/notes/presentation/note_tab_view.dart';
import 'package:karmashala_ui/code.dart';

import '../../features/scale/scale_harness.dart';
import '../../features/terminal/fake_instance.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import 'package:agent_cli/process.dart';

/// A note body's right-click menu is the editor's, and of the file tab's
/// entries only what a selection can become — a note has no path, and a note
/// made from a note is not a capture.
void main() {
  testWidgets('a note gets the editing subset, with no path entries', (
    tester,
  ) async {
    commandKeyIsMeta = false;
    // The clipboard is asked whether Paste has anything; nothing answers a
    // platform channel in a test unless something is set to.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async =>
          call.method == 'Clipboard.hasStrings' ? {'value': false} : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final db = CountingDatabase();
    addTearDown(db.close);
    final server = FakeDataServer();
    server.environmentRows.upsert(
  localHostEnvironment(FixedClock(testTime).nowUtc()),
);
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation());
    final data = await server.override();
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        data,
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
        ),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
      ],
    );
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Future<void> settle() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
    }

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const KarmashalaApp(),
      ),
    );
    await settle();
    final note = container.read(notesProvider.notifier).capture(body: '');
    openNoteTab(
      tester.element(find.byType(WorkbenchView)) as WidgetRef,
      note.id,
    );
    await settle();

    final body = find.descendant(
      of: find.byType(NoteTabView),
      matching: find.byType(AppCodeEditor),
    );
    final controller = tester.widget<AppCodeEditor>(body).controller;
    controller.text = 'an idea worth sending';
    controller.selectAll();
    await tester.pump();

    final editor = tester.widget<AppCodeEditor>(body);
    expect(editor.focusNode!.hasFocus, isTrue);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f10);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    for (final label in ['Copy', 'Find…', 'Go to line…']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('Send selection to session'), findsOneWidget);
    for (final label in [
      'Copy path',
      'Reveal in Files panel',
      'Create note from selection',
      'Word wrap',
    ]) {
      expect(find.text(label), findsNothing, reason: label);
    }

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
