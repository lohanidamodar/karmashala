import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_panel.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_ui/theme.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/test_machine.dart';

/// Naming a preset from a tab's menu: the name comes back, and the field's
/// controller goes with the dialog rather than outliving it.
void main() {
  late TestMachine db;
  late ProviderContainer container;

  setUp(() {
    db = TestMachine();
    container = fakeTerminalContainer(machine: db);
  });

  tearDown(() {
    container.dispose();
  });

  /// Every [TextEditingController] created while [body] runs, and whether each
  /// was disposed by the end of it.
  Future<Map<Object, bool>> trackControllers(
    Future<void> Function() body,
  ) async {
    final controllers = <Object, bool>{};
    void listener(ObjectEvent event) {
      if (event.object is! TextEditingController) return;
      if (event is ObjectCreated) controllers[event.object] = false;
      if (event is ObjectDisposed) controllers[event.object] = true;
    }

    FlutterMemoryAllocations.instance.addListener(listener);
    try {
      await body();
    } finally {
      FlutterMemoryAllocations.instance.removeListener(listener);
    }
    return controllers;
  }

  Future<void> openSaveDialog(WidgetTester tester) async {
    await tester.tap(
      find.byType(TerminalTabChip).first,
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save this layout as a preset…'));
    await tester.pumpAndSettle();
  }

  for (final button in ['Save', 'Cancel']) {
    testWidgets('closing the name dialog with $button disposes its field', (
      tester,
    ) async {
      container
          .read(terminalSessionsControllerProvider.notifier)
          .openTab(TerminalProfile.powerShell, workingDirectory: r'C:\src\p');
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const Scaffold(body: WorkbenchView()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final controllers = await trackControllers(() async {
        await openSaveDialog(tester);
        await tester.enterText(find.byType(TextField), 'Two and one');
        await tester.tap(find.text(button));
        await tester.pumpAndSettle();
      });

      expect(controllers, isNotEmpty);
      expect(
        controllers.values,
        everyElement(isTrue),
        reason: 'a controller outlived the dialog',
      );
      expect(find.byType(AlertDialog), findsNothing);
    });
  }
}
