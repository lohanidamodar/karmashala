import 'dart:io';

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/terminal/application/scrollback_autosave.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/data/scrollback_codec.dart';
import 'package:karmashala/src/features/terminal/data/terminal_instance.dart';
import 'package:karmashala/src/features/terminal/domain/pane_layout.dart';
import 'package:karmashala/src/features/terminal/domain/pane_liveness.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:xterm/xterm.dart';

/// End-to-end proof of keep-alive and restore against **real ConPTY processes**
/// and a **real SQLite file** — the two things a fake can always be made to
/// agree with.
///
/// Keep-alive is asserted at the operating-system level, not in the app's own
/// bookkeeping: the shell appends to a file on a timer, and the question "did
/// closing the tab kill it?" is answered by whether that file keeps growing.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory work;

  setUp(() => work = Directory.systemTemp.createTempSync('cg_session_'));
  tearDown(() {
    try {
      work.deleteSync(recursive: true);
    } catch (_) {}
  });

  AppDatabase openDb() =>
      AppDatabase(sqlite3.open(p.join(work.path, 'db.sqlite')));

  ProviderContainer containerOver(AppDatabase db) => ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      // A real periodic timer outlives the test and trips the pending-timer
      // check; saving is driven explicitly here.
      scrollbackAutosaveFactoryProvider.overrideWithValue(
        ({required onTick}) => ScrollbackAutosave(
          onTick: onTick,
          schedule: (_, _) => Object(),
          cancel: (_) {},
        ),
      ),
    ],
  );

  /// Waits until [test] holds, or gives up after [within].
  Future<bool> waitFor(
    bool Function() test, {
    Duration within = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(within);
    while (DateTime.now().isBefore(deadline)) {
      if (test()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    return test();
  }

  int beats(File file) => file.existsSync()
      ? file.readAsLinesSync().where((l) => l.isNotEmpty).length
      : 0;

  /// The interval the heartbeat shell below writes at.
  const beatInterval = Duration(milliseconds: 200);

  /// Waits until [file] has stopped growing for two whole beats, or gives up.
  ///
  /// The observable for "the process is dead" — polled, because ending a
  /// session is a `taskkill` round trip whose latency is not a fixed number of
  /// seconds on a loaded machine.
  Future<bool> waitUntilStopped(
    File file, {
    Duration within = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(within);
    while (DateTime.now().isBefore(deadline)) {
      final before = beats(file);
      await Future<void>.delayed(beatInterval * 2);
      if (beats(file) == before) return true;
    }
    return false;
  }

  testWidgets('closing a tab leaves the process running and re-attachable', (
    tester,
  ) async {
    final db = openDb();
    addTearDown(db.close);
    final container = containerOver(db);
    addTearDown(container.dispose);
    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );

    final heartbeat = File(p.join(work.path, 'heartbeat.txt'));
    final tabId = controller.openTab(TerminalProfile.powerShell);
    final pane = container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .layout
        .panes
        .single;
    final instance = controller.instanceFor(pane)!;

    // A long-running job of exactly the kind closing a tab used to destroy.
    instance.terminal.textInput(
      r'$i=0; while ($true) { $i++; '
      'Add-Content -Path "${heartbeat.path.replaceAll(r'\', r'\\')}" '
      r'-Value "beat $i"; Write-Output "BEAT $i"; '
      r'Start-Sleep -Milliseconds 200 }',
    );
    instance.terminal.keyInput(TerminalKey.enter);

    expect(
      await waitFor(() => beats(heartbeat) >= 2),
      isTrue,
      reason: 'the job never started',
    );

    // The moment of truth: close the tab.
    controller.closeTab(tabId);
    final atClose = beats(heartbeat);

    final state = container.read(terminalSessionsControllerProvider);
    expect(state.tabs, isEmpty, reason: 'the view is gone');
    expect(state.detached.map((s) => s.paneId), [pane]);
    expect(state.livenessOf(pane), PaneLiveness.live);

    // The only evidence that matters: the OS process is still doing work.
    expect(
      await waitFor(() => beats(heartbeat) > atClose + 3),
      isTrue,
      reason: 'closing the tab killed the process',
    );

    // Re-attaching gets the same session back, still live and still producing.
    expect(controller.reattachSession(pane), isNotNull);
    expect(controller.instanceFor(pane), same(instance));
    final reattached = container.read(terminalSessionsControllerProvider);
    expect(reattached.tabs.single.layout.panes, [pane]);
    expect(reattached.livenessOf(pane), PaneLiveness.live);
    expect(encodeScrollback(instance.terminal), contains('BEAT'));

    // Ending it is what actually stops the work.
    controller.endSession(pane);
    expect(
      await waitUntilStopped(heartbeat),
      isTrue,
      reason: 'ending the session did not stop the process',
    );
    // And it stays stopped. Proving a negative needs a window rather than a
    // poll, but five beats is enough of one, and it starts from a file that has
    // already been observed to be still.
    final atEnd = beats(heartbeat);
    await Future<void>.delayed(beatInterval * 5);
    expect(
      beats(heartbeat),
      atEnd,
      reason: 'the killed process started writing again',
    );
  }, timeout: const Timeout(Duration(seconds: 120)));

  testWidgets('a restart brings back the layout and scrollback, dormant', (
    tester,
  ) async {
    final first = openDb();
    final before = containerOver(first);
    final controller = before.read(terminalSessionsControllerProvider.notifier);

    controller.openTab(TerminalProfile.powerShell, workingDirectory: work.path);
    final left = before
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .layout
        .panes
        .single;
    // Splitting leaves the new region empty, so the second shell is asked for
    // explicitly.
    final right = controller.openInSlot(
      controller.splitPane(SplitAxis.horizontal)!,
      TerminalProfile.commandPrompt,
    )!;

    controller.instanceFor(left)!.terminal
      ..textInput('echo MARKER_LEFT')
      ..keyInput(TerminalKey.enter);
    controller.instanceFor(right)!.terminal
      ..textInput('echo MARKER_RIGHT')
      ..keyInput(TerminalKey.enter);

    expect(
      await waitFor(
        () =>
            encodeScrollback(
              controller.instanceFor(left)!.terminal,
            ).contains('MARKER_LEFT') &&
            encodeScrollback(
              controller.instanceFor(right)!.terminal,
            ).contains('MARKER_RIGHT'),
      ),
      isTrue,
      reason: 'the shells never echoed',
    );

    // What quitting does: snapshot, then the processes die with the app.
    controller.persistLayout();
    before.dispose();
    first.close();

    // What launching does: a fresh container over the same file on disk.
    final second = openDb();
    addTearDown(second.close);
    final after = containerOver(second);
    addTearDown(after.dispose);
    final restored = after.read(terminalSessionsControllerProvider);
    final restoredController = after.read(
      terminalSessionsControllerProvider.notifier,
    );

    expect(restored.tabs.length, 1);
    expect(restored.tabs.single.layout.panes, unorderedEquals([left, right]));
    expect(restored.activeTabId, restored.tabs.single.id);

    // Scrollback came back...
    expect(
      encodeScrollback(restoredController.instanceFor(left)!.terminal),
      contains('MARKER_LEFT'),
    );
    expect(
      encodeScrollback(restoredController.instanceFor(right)!.terminal),
      contains('MARKER_RIGHT'),
    );

    // ...and nothing was started to bring it back.
    for (final pane in [left, right]) {
      expect(restored.livenessOf(pane), PaneLiveness.restored);
      expect(
        restoredController.instanceFor(pane),
        isA<DormantTerminalInstance>(),
      );
    }

    // The user asks, and only then does a process appear — in the directory the
    // pane was launched in, with its history above it.
    restoredController.startPane(left);
    expect(
      after.read(terminalSessionsControllerProvider).livenessOf(left),
      PaneLiveness.live,
    );
    final started = restoredController.instanceFor(left)!;
    expect(started.workingDirectory, work.path);

    expect(
      await waitFor(
        () => encodeScrollback(started.terminal).contains('MARKER_LEFT'),
      ),
      isTrue,
      reason: 'the started pane lost the history it was restored with',
    );
    // The other pane stayed dormant: starting one is not starting all.
    expect(
      after.read(terminalSessionsControllerProvider).livenessOf(right),
      PaneLiveness.restored,
    );
  }, timeout: const Timeout(Duration(seconds: 120)));
}
