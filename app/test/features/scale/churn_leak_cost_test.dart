import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:flutter_test/flutter_test.dart';

import 'scale_harness.dart';

/// **The churn/leak gate** — and deliberately *not* the "8-hour churn/leak
/// soak" the backlog asked for, because that one cannot honestly be
/// built here and this one is more useful.
///
/// A gate that runs for eight hours is a gate nobody runs, and a gate that runs
/// for two seconds and calls itself an eight-hour soak converts an open
/// question into a false answer. What an eight-hour session actually *does* to
/// this app is not the passage of time — nothing here is driven by the wall
/// clock except a 20 s autosave tick, which
/// `quiet_soak_cost_test.dart` already fires 180 times for nothing. It is
/// **churn**: sessions appearing, printing, being split, being closed while
/// still running (a disconnect: the server keeps the terminal), and others
/// being ended for good. So that is what this compresses — the same cycle, N times, asserting
/// that nothing retained grows with N.
///
/// That is a leak gate, honestly named. It cannot see fragmentation, native
/// allocator growth, or anything that only shows up as RSS on a real machine
/// over real hours; what it can see is every place this app *holds a
/// reference*, and those are the failures that turn a day of use into a
/// restart. Counted, never timed, like everything else here.
///
/// Each of these is one map the controller keeps or one object it owns:
///
/// * **undisposed panes** — a `TerminalInstance` built and never disposed. In
///   production that is a PTY, a process and a parsed buffer.
/// * **terminal listeners** — the controller attaches a dirty-tracking
///   listener per live pane, and `_unlisten` exists to take it off. xterm's
///   `Observable.listeners` is a public set, so this is read directly.
/// * **stored rows** — `terminal_tabs` and `terminal_panes`, plus the backup
///   copies, which a save takes whenever it loses something.
/// * **the dirty set, and the ages beside it** — `dirtyPanes` and
///   `oldestUnsaved` from `persistenceTelemetry`, the two numbers Settings →
///   Diagnostics shows. They have to agree: an unsaved *age* with nothing
///   unsaved is a pane that has gone still being counted.
void main() {
  /// Cycles to run. Forty is not eight hours of anything; it is enough for a
  /// per-cycle leak to be unmistakable next to the one-cycle control, which is
  /// the only property a compressed churn gate can honestly claim.
  const scale = [1, 10, 40];

  /// Everything a session does over its life, in one turn: it appears, prints,
  /// gets a split beside it that is then closed, and has its own tab closed
  /// while it is still running — which drops the pane, the server keeping the
  /// terminal. A second session then appears, prints, and is ended for good.
  /// (Until 2026-09-30 the closed one was kept with no tab and reopened from a
  /// background list; that list is gone.)
  void cycle(ScaleLayout layout) {
    final controller = layout.controller;
    final pane = layout.openPane();
    layout.fill(pane, lines: 60);

    // A split beside it, used and then closed.
    final slot = controller.splitPane(SplitAxis.horizontal)!;
    final beside = controller.openInSlot(slot, TerminalProfile.commandPrompt)!;
    layout.fill(beside, lines: 20);
    controller.closePane(beside, detach: false);

    // Closed with output on screen and still running: the view goes, and
    // this window keeps nothing of it.
    final tab = layout.state.tabs
        .firstWhere((tab) => tab.layout.panes.contains(pane))
        .id;
    controller.closeTab(tab, detach: true);
    expect(
      controller.instanceFor(pane),
      isNull,
      reason: 'a closed tab drops its pane, or this cycle is testing nothing',
    );

    // And one ended outright, the other way a session leaves.
    final ended = layout.openPane();
    layout.fill(ended, lines: 60);
    controller.endSession(ended);
  }

  /// Everything this gate watches, in one reading.
  Map<String, Object?> retained(ScaleLayout layout) {
    final telemetry = layout.controller.persistenceTelemetry;
    return {
      'undisposedPanes': layout.undisposedPanes,
      'terminalListeners': layout.liveTerminalListeners,
      'tabs': layout.state.tabs.length,
      'detached': layout.state.detached.length,
      'livePanes': telemetry.livePanes,
      'dirtyPanes': telemetry.dirtyPanes,
      'unsavedAgeReported': telemetry.oldestUnsaved != null,
      'storedTabRows': layout.storedTabRows,
      'storedPaneRows': layout.storedPaneRows,
      'backupTabRows': layout.backupTabRows,
      'backupPaneRows': layout.backupPaneRows,
    };
  }

  group('churning sessions', () {
    /// Filled by the cases below so the shape can be asserted across them.
    final readings = <int, Map<String, Object?>>{};

    for (final cycles in scale) {
      test('$cycles times leaves nothing behind', () {
        final layout = ScaleLayout();
        addTearDown(layout.dispose);

        for (var i = 0; i < cycles; i++) {
          cycle(layout);
        }

        final reading = retained(layout);
        readings[cycles] = reading;
        // ignore: avoid_print
        print('CHURN-LEAK cycles=$cycles $reading');

        expect(
          layout.instancesByPane,
          hasLength(cycles * 3),
          reason: 'three panes per cycle were built, or the cycle changed',
        );
        expect(
          reading['undisposedPanes'],
          0,
          reason: 'every pane of every cycle was closed',
        );
        expect(
          reading['terminalListeners'],
          0,
          reason:
              'a closed pane whose terminal is still listened to is a buffer '
              'the controller can never let go of',
        );
        expect(reading['tabs'], 0);
        expect(reading['detached'], 0);
        expect(reading['livePanes'], 0);
        expect(reading['dirtyPanes'], 0);
        expect(
          reading['unsavedAgeReported'],
          isFalse,
          reason:
              'Diagnostics may not report an oldest-unsaved age with nothing '
              'unsaved: that age belongs to a pane that no longer exists, and '
              'the entry behind it is never dropped',
        );
        expect(
          reading['storedPaneRows'],
          0,
          reason: 'the user ended every session, so the store holds none',
        );
      });
    }

    test('so nothing retained grows with the number of cycles', () {
      expect(readings.keys, containsAll(scale));
      for (final key in readings[scale.first]!.keys) {
        expect(
          {for (final entry in readings.entries) entry.value[key]},
          hasLength(1),
          reason:
              '$key differs between 1 and ${scale.last} cycles: '
              '${{for (final e in readings.entries) e.key: e.value[key]}}',
        );
      }
    });
  });

  group('churning a layout that is never emptied', () {
    /// The other shape, and the one a long day actually looks like: a floor of
    /// sessions the user keeps, with work coming and going around it. A leak
    /// that only shows up once everything is closed would be missed by the
    /// group above.
    final readings = <int, Map<String, Object?>>{};

    for (final cycles in scale) {
      test('$cycles times returns to the floor it started from', () {
        final layout = ScaleLayout();
        addTearDown(layout.dispose);
        final floor = layout.openPanes(5, linesPerPane: 60);
        layout.settle();
        final before = retained(layout);

        for (var i = 0; i < cycles; i++) {
          cycle(layout);
        }
        layout.settle();

        final reading = retained(layout);
        readings[cycles] = reading;
        // ignore: avoid_print
        print('CHURN-LEAK-FLOOR cycles=$cycles $reading');

        expect(
          reading,
          before,
          reason: 'the layout must come back to exactly what it was',
        );
        for (final pane in floor) {
          expect(
            layout.controller.instanceFor(pane),
            isNotNull,
            reason: 'the sessions the user kept are still there',
          );
          expect(layout.storedScrollback(pane), isNotEmpty);
        }
      });
    }

    test('and the floor costs the same however much churned around it', () {
      expect(readings.keys, containsAll(scale));
      for (final key in readings[scale.first]!.keys) {
        expect(
          {for (final entry in readings.entries) entry.value[key]},
          hasLength(1),
          reason:
              '$key differs between 1 and ${scale.last} cycles: '
              '${{for (final e in readings.entries) e.key: e.value[key]}}',
        );
      }
    });
  });
}
