import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/domain/pane_layout.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_instance.dart';

/// What persistence owes, reported so it can be watched.
///
/// The numbers are diagnostics — nothing behaves differently because of them —
/// so what these tests pin is that they are *true*: a clean layout owes
/// nothing, output creates a debt, a write clears it, and a write that has not
/// happened is reported as unrecorded rather than as a zero that reads like a
/// measurement.
void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late TerminalSessionsController controller;

  setUp(() {
    WidgetsFlutterBinding.ensureInitialized();
    db = AppDatabase.memory();
    container = fakeTerminalContainer(database: db);
    controller = container.read(terminalSessionsControllerProvider.notifier);
  });

  tearDown(() {
    container.dispose();
    db.close();
  });

  String openSecondPane() {
    controller.openTab(TerminalProfile.powerShell);
    return controller.openInSlot(
      controller.splitPane(SplitAxis.horizontal)!,
      TerminalProfile.commandPrompt,
    )!;
  }

  test('a layout nobody has typed into owes nothing', () {
    openSecondPane();
    controller.saveDirtyScrollback();

    final telemetry = controller.persistenceTelemetry;

    expect(telemetry.livePanes, 2);
    expect(telemetry.dirtyPanes, 0);
    expect(telemetry.oldestUnsaved, isNull);
  });

  test('output puts a pane in debt, and a write clears it', () {
    final second = openSecondPane();
    controller.saveDirtyScrollback();
    controller.instanceFor(second)!.terminal.write('output\r\n');

    expect(controller.persistenceTelemetry.dirtyPanes, 1);
    expect(controller.persistenceTelemetry.oldestUnsaved, isNotNull);

    controller.saveDirtyScrollback();

    expect(controller.persistenceTelemetry.dirtyPanes, 0);
    expect(controller.persistenceTelemetry.oldestUnsaved, isNull);
  });

  test('a write that has not happened is not recorded, not zero', () {
    openSecondPane();

    // A restored layout writes nothing until something asks it to, and a
    // "0 panes in 0ms" would read as a measurement of a write that never ran.
    expect(controller.persistenceTelemetry.lastWrite, isNull);
  });

  test('and once one has run it says what it covered', () {
    final second = openSecondPane();
    controller.instanceFor(second)!.terminal.write('output\r\n');

    controller.saveDirtyScrollback();

    final write = controller.persistenceTelemetry.lastWrite;
    expect(write, isNotNull);
    expect(write!.panes, greaterThanOrEqualTo(1));
    expect(write.took, greaterThanOrEqualTo(Duration.zero));
  });

  test('a closed pane stops owing anything', () {
    final second = openSecondPane();
    controller.instanceFor(second)!.terminal.write('output\r\n');
    expect(controller.persistenceTelemetry.dirtyPanes, 1);

    controller.closePane(second);

    // The debt goes with the pane rather than being carried to shutdown: a
    // pane that no longer exists cannot be written, and counting it would make
    // the number that says "we are behind" permanently wrong.
    controller.saveDirtyScrollback();
    expect(controller.persistenceTelemetry.dirtyPanes, 0);
    // Both halves, not just the count. This test originally checked only
    // `dirtyPanes` and passed while `_releasePane` was dropping the pane from
    // the dirty set and leaving its timestamp behind — so the panel reported an
    // ever-growing "longest wait" beside "0 panes owing", which is precisely
    // the falling-behind signal it exists to give. A scale gate found it; the
    // count alone could not.
    expect(controller.persistenceTelemetry.oldestUnsaved, isNull);
  });

  test('and a pane closed while dirty leaves no age behind it', () {
    final second = openSecondPane();
    controller.saveDirtyScrollback();
    controller.instanceFor(second)!.terminal.write('output\r\n');
    expect(controller.persistenceTelemetry.oldestUnsaved, isNotNull);

    // Closed without a save in between: the pane's debt is forgiven by its
    // disposal, not by having been written.
    controller.closePane(second);

    final telemetry = controller.persistenceTelemetry;
    expect(telemetry.dirtyPanes, 0);
    expect(telemetry.oldestUnsaved, isNull);
  });
}
