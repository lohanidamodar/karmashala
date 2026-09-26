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

/// Ctrl+S from a note's focused body on a desktop platform. `note_tab_test`
/// runs on the test default (Android), where `re_editor` binds no shortcuts,
/// so it could not see the editor consuming the chord.
void main() {
  testWidgets('Ctrl+S from the focused note body saves at once', (
    tester,
  ) async {
    commandKeyIsMeta = false;
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

    // Empty, so the tab opens on the editor with the body focused.
    final note = container.read(notesProvider.notifier).capture(body: '');
    openNoteTab(
      tester.element(find.byType(WorkbenchView)) as WidgetRef,
      note.id,
    );
    await settle();

    final body = tester.widget<AppCodeEditor>(
      find.descendant(
        of: find.byType(NoteTabView),
        matching: find.byType(AppCodeEditor),
      ),
    );
    expect(body.focusNode!.hasFocus, isTrue);
    body.controller.text = 'kept at once';
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    // Less than the note autosave delay: only the chord can have written it.
    await tester.pump();
    await tester.pump();

    expect(server.notes[note.id]!.body, 'kept at once');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
