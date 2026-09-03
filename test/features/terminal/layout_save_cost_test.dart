import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/terminal/application/scrollback_autosave.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/data/command_block_recorder.dart';
import 'package:karmashala/src/features/terminal/data/terminal_instance.dart';
import 'package:karmashala/src/features/terminal/data/terminal_layout_dao.dart';
import 'package:karmashala/src/features/terminal/domain/agent_pane_launch.dart';
import 'package:karmashala/src/features/terminal/domain/pane_layout.dart';
import 'package:karmashala/src/features/terminal/domain/pane_liveness.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

/// What a layout save costs.
///
/// A save runs on every structural change — open, split, close, detach, end,
/// start — and again on quit, and it used to re-encode **every** open pane each
/// time, however little had happened. Loop 48 measured the encode at ~5 ms per
/// pane holding a full durable window, so a split with eight busy panes open
/// paid ~40 ms of main-isolate work to write seven unchanged strings back.
///
/// These tests pin the fix: a pane is re-encoded only when its buffer moved
/// since the last time it was written.
void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late TerminalSessionsController controller;
  late TerminalLayoutDao dao;

  /// Every delay the autosave has armed a tick at, in order.
  final armed = <Duration>[];

  setUp(() {
    armed.clear();
    db = AppDatabase.memory();
    dao = TerminalLayoutDao(db);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        scrollbackAutosaveFactoryProvider.overrideWithValue(
          ({required onTick}) => ScrollbackAutosave(
            onTick: onTick,
            // Recorded rather than run: the cadence the controller asks for is
            // the assertion, and a real timer would outlive the test.
            schedule: (interval, callback) {
              armed.add(interval);
              return Object();
            },
            cancel: (_) {},
          ),
        ),
        shellIntegrationEnabledProvider.overrideWithValue(false),
        terminalInstanceFactoryProvider.overrideWithValue(
          ({
            required id,
            required profile,
            workingDirectory,
            restoredScrollback,
            shellIntegration = false,
            agentLaunch,
            adoptTerminal,
          }) => _CountingInstance(
            id: id,
            title: profile.label,
            profileId: profile.id,
            workingDirectory: workingDirectory,
            restoredScrollback: restoredScrollback,
          ),
        ),
      ],
    );
    controller = container.read(terminalSessionsControllerProvider.notifier);
  });

  tearDown(() {
    container.dispose();
    db.close();
  });

  _CountingInstance instance(String paneId) =>
      controller.instanceFor(paneId)! as _CountingInstance;

  /// Opens a tab with two panes and returns their ids.
  (String, String) twoPanes() {
    controller.openTab(TerminalProfile.powerShell);
    final tab = container.read(terminalSessionsControllerProvider).tabs.single;
    final first = tab.layout.panes.single;
    // Splitting clears room and starts nothing, so a second *live* pane is
    // two calls now: divide, then fill.
    final second = controller.openInSlot(
      controller.splitPane(SplitAxis.horizontal)!,
      TerminalProfile.commandPrompt,
    )!;
    return (first, second);
  }

  String storedScrollbackFor(String paneId) {
    for (final tab in dao.loadLayout().tabs) {
      for (final pane in tab.panes) {
        if (pane.id == paneId) return pane.scrollback;
      }
    }
    fail('pane $paneId was not persisted');
  }

  test('a save with nothing written since the last one re-encodes nothing', () {
    final (first, second) = twoPanes();
    instance(first).terminal.write('one\r\n');
    instance(second).terminal.write('two\r\n');

    controller.persistLayout();
    final after = [instance(first).encodes, instance(second).encodes];
    expect(after, everyElement(greaterThan(0)));

    controller.persistLayout();
    controller.persistLayout();

    expect([instance(first).encodes, instance(second).encodes], after);
  });

  test('only the pane that changed is re-encoded', () {
    final (first, second) = twoPanes();
    instance(first).terminal.write('one\r\n');
    instance(second).terminal.write('two\r\n');
    controller.persistLayout();
    final quiet = instance(first).encodes;
    final busy = instance(second).encodes;

    instance(second).terminal.write('more\r\n');
    controller.persistLayout();

    expect(instance(first).encodes, quiet, reason: 'untouched pane');
    expect(instance(second).encodes, busy + 1, reason: 'pane that wrote');
  });

  test('reusing an encoding never stores stale scrollback', () {
    final (_, second) = twoPanes();
    instance(second).terminal.write('first line\r\n');
    controller.persistLayout();
    expect(storedScrollbackFor(second), contains('first line'));

    instance(second).terminal.write('second line\r\n');
    controller.persistLayout();

    final stored = storedScrollbackFor(second);
    expect(stored, contains('first line'));
    expect(stored, contains('second line'));
  });

  test('the autosave tick leaves nothing for the next save to redo', () {
    final (first, second) = twoPanes();
    instance(first).terminal.write('one\r\n');
    instance(second).terminal.write('two\r\n');

    expect(controller.saveDirtyScrollback(), unorderedEquals([first, second]));
    final afterTick = [instance(first).encodes, instance(second).encodes];

    // This is the quit path: everything the autosave already wrote is a
    // cache hit, so quitting flushes only what changed since the last tick.
    controller.persistLayout();

    expect([instance(first).encodes, instance(second).encodes], afterTick);
  });

  test(
    'a pane that never wrote anything is still encoded once, and stored',
    () {
      final (first, _) = twoPanes();
      controller.persistLayout();
      expect(instance(first).encodes, 1);
      expect(storedScrollbackFor(first), isEmpty);
    },
  );

  test('a closed pane does not keep its cached encoding alive', () {
    final (first, second) = twoPanes();
    instance(second).terminal.write('two\r\n');
    controller.persistLayout();

    controller.closePane(second, detach: false);
    controller.persistLayout();

    // The surviving pane is still saved correctly; the closed one is gone.
    expect(dao.loadLayout().tabs.single.panes.map((p) => p.id), [first]);
  });

  test('a tick is capped, so its cost does not grow with the number of panes', () {
    // The scale target forbids work proportional to all panes on a timer
    //. A zero budget is the extreme of the same rule:
    // one pane always gets written — progress is guaranteed — and no more.
    controller.openTab(TerminalProfile.powerShell);
    for (var i = 0; i < 5; i++) {
      controller.openInSlot(
        controller.splitPane(SplitAxis.horizontal)!,
        TerminalProfile.powerShell,
      );
    }
    final panes = container
        .read(terminalSessionsControllerProvider)
        .tabs
        .single
        .layout
        .panes;
    expect(panes.length, 6);
    for (final paneId in panes) {
      instance(paneId).terminal.write('output\r\n');
    }

    expect(controller.saveDirtyScrollback(budget: Duration.zero).length, 1);
    expect(controller.hasDirtyScrollback, isTrue);

    // The backlog drains over following ticks rather than being dropped.
    var ticks = 1;
    while (controller.hasDirtyScrollback && ticks < 50) {
      controller.saveDirtyScrollback(budget: Duration.zero);
      ticks++;
    }
    expect(controller.hasDirtyScrollback, isFalse);
    expect(ticks, panes.length);
  });

  group('a structural change', () {
    /// Grows the single open tab by [extra] live panes. Splitting clears room
    /// and starts nothing, so each one is two calls.
    void grow(int extra) {
      for (var i = 0; i < extra; i++) {
        controller.openInSlot(
          controller.splitPane(SplitAxis.horizontal)!,
          TerminalProfile.powerShell,
        );
      }
    }

    List<String> openPanes() => container
        .read(terminalSessionsControllerProvider)
        .tabs
        .single
        .layout
        .panes
        .where((id) => controller.instanceFor(id) != null)
        .toList();

    int encodesAcross(List<String> panes) =>
        panes.fold(0, (sum, id) => sum + instance(id).encodes);

    /// [n] live panes, all stored, and then all of them busy — the state a
    /// layout is in whenever anything is actually running in it.
    List<String> busyLayout(int n) {
      controller.openTab(TerminalProfile.powerShell);
      grow(n - 1);
      controller.persistLayout();
      final panes = openPanes();
      expect(panes, hasLength(n));
      for (final paneId in panes) {
        instance(paneId).terminal.write('output\r\n');
      }
      expect(controller.hasDirtyScrollback, isTrue);
      return panes;
    }

    /// Filled by the cases below so the shape can be asserted across them.
    final encodes = <int, int>{};

    for (final n in [1, 10, 50]) {
      test('over $n busy panes, re-encodes only the pane it adds', () {
        final panes = busyLayout(n);
        final before = encodesAcross(panes);

        final added = controller.openInSlot(
          controller.splitPane(SplitAxis.horizontal)!,
          TerminalProfile.powerShell,
        )!;

        expect(
          encodesAcross(panes),
          before,
          reason: 'the panes that were already open have not moved on screen',
        );
        expect(instance(added).encodes, 1, reason: 'the pane that appeared');
        encodes[n] = encodesAcross(panes) - before + instance(added).encodes;
      });
    }

    test('so its encode cost does not grow with the layout', () {
      expect(encodes.keys, containsAll([1, 10, 50]));
      expect(
        encodes.values.toSet(),
        hasLength(1),
        reason: 'encodes per structural change: $encodes',
      );
    });

    /// Filled by the quit cases below.
    final quitEncodes = <int, int>{};

    for (final n in [1, 10, 50]) {
      test('quitting with $n busy panes re-encodes exactly the dirty ones', () {
        final panes = busyLayout(n);
        final before = encodesAcross(panes);

        // The quit path, not a structural one: `persistLayout` is the last
        // write before the process ends, so unlike a structural save it must
        // refresh rather than reuse — anything it leaves behind is gone.
        controller.persistLayout();

        quitEncodes[n] = encodesAcross(panes) - before;
        expect(
          quitEncodes[n],
          n,
          reason: 'one encode per dirty pane, and no more',
        );
        expect(controller.hasDirtyScrollback, isFalse);
      });
    }

    test('and a second quit-time save re-encodes nothing at all', () {
      // The property that makes the first number safe: cost tracks what
      // changed, not what is open. A layout nobody has typed into costs
      // nothing to write however many panes it holds.
      final panes = busyLayout(50);
      controller.persistLayout();
      final after = encodesAcross(panes);

      controller.persistLayout();

      expect(encodesAcross(panes), after);
    });

    test('so quit cost is bounded by what changed, not by the layout', () {
      // Deliberately *not* the same shape as the structural assertion above,
      // which pins a constant. Quitting has to write every pane that moved, so
      // its cost is linear in dirty panes by design — a budget here would drop
      // the user's scrollback on the way out, which is the one thing this path
      // exists to prevent. What is asserted is that the constant is 1: no pane
      // is encoded twice, and no clean pane is encoded at all.
      expect(quitEncodes.keys, containsAll([1, 10, 50]));
      for (final entry in quitEncodes.entries) {
        expect(entry.value, entry.key, reason: 'quit encodes: $quitEncodes');
      }
    });

    test('leaves those panes still owing the autosave a write', () {
      final panes = busyLayout(4);
      controller.openInSlot(
        controller.splitPane(SplitAxis.horizontal)!,
        TerminalProfile.powerShell,
      );

      // Nothing was dropped: the text is late, not lost.
      expect(
        controller.saveDirtyScrollback(budget: const Duration(minutes: 1)),
        containsAll(panes),
      );
      for (final paneId in panes) {
        expect(storedScrollbackFor(paneId), contains('output'));
      }
    });

    test('and quitting writes what it left, without waiting for a tick', () {
      final panes = busyLayout(4);
      controller.openInSlot(
        controller.splitPane(SplitAxis.horizontal)!,
        TerminalProfile.powerShell,
      );

      // The teardown save is the one that must never defer anything.
      controller.persistLayout();

      expect(controller.hasDirtyScrollback, isFalse);
      for (final paneId in panes) {
        expect(storedScrollbackFor(paneId), contains('output'));
      }
    });

    test('still stores a pane the store has never seen', () {
      // A new pane has no encoding to reuse, so deferring would store nothing
      // for it at all — the one case a structural save has to encode. Its
      // *row* has to exist as well, or a restart brings back a layout with a
      // hole in it.
      controller.openTab(TerminalProfile.powerShell);
      final first = openPanes().single;
      instance(first).terminal.write('before the split\r\n');

      final added = controller.openInSlot(
        controller.splitPane(SplitAxis.horizontal)!,
        TerminalProfile.commandPrompt,
      )!;

      expect(instance(added).encodes, 1);
      expect(dao.loadLayout().tabs.single.panes.map((p) => p.id), [
        first,
        added,
      ]);
      // And the text the split did *not* stop to re-encode is owed, not lost.
      expect(controller.hasDirtyScrollback, isTrue);
      controller.saveDirtyScrollback(budget: const Duration(minutes: 1));
      expect(storedScrollbackFor(first), contains('before the split'));
    });

    test('asks the autosave to come back on its catch-up cadence', () {
      busyLayout(4);
      armed.clear();

      controller.openInSlot(
        controller.splitPane(SplitAxis.horizontal)!,
        TerminalProfile.powerShell,
      );

      expect(
        armed,
        contains(kScrollbackAutosaveCatchUp),
        reason:
            'text a structural save left behind must not wait for the idle '
            'tick that happened to be armed',
      );
    });
  });

  test('a generous budget still saves everything in one tick', () {
    final (first, second) = twoPanes();
    instance(first).terminal.write('one\r\n');
    instance(second).terminal.write('two\r\n');

    expect(
      controller.saveDirtyScrollback(budget: const Duration(minutes: 1)),
      unorderedEquals([first, second]),
    );
    expect(controller.hasDirtyScrollback, isFalse);
  });
}

/// A process-free instance whose terminal counts how many times the scrollback
/// encoder has read it.
///
/// `Terminal.mainBuffer` is the codec's single entry point into the buffer — it
/// reads it once per `encodeScrollback` call and nothing else in the controller
/// or the DAO touches the getter — so this counter *is* the encode count.
class _CountingInstance implements TerminalInstance {
  @override
  int? get exitCode => null;

  _CountingInstance({
    required this.id,
    required this.title,
    required this.profileId,
    this.workingDirectory,
    String? restoredScrollback,
  }) {
    terminal = _CountingTerminal()..resize(40, 10);
    if (restoredScrollback != null && restoredScrollback.isNotEmpty) {
      terminal.write(restoredScrollback);
    }
  }

  @override
  final String id;
  @override
  final String title;
  @override
  final String profileId;
  @override
  final String? workingDirectory;

  /// Never moves: nothing runs here to report a `cd`.
  @override
  late final ValueListenable<String?> directory = UnchangingValue(
    workingDirectory,
  );

  @override
  final AgentPaneLaunch? agentLaunch = null;

  @override
  late final _CountingTerminal terminal;
  @override
  final TerminalController controller = TerminalController();
  @override
  final FocusNode focusNode = FocusNode();
  @override
  final ScrollController scrollController = ScrollController();
  @override
  CommandBlockRecorder? get commandBlocks => null;
  @override
  ValueListenable<PaneLiveness> get liveness => _liveness;
  final _liveness = ValueNotifier(PaneLiveness.live);

  int get encodes => terminal.mainBufferReads;

  bool _disposed = false;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _liveness.value = PaneLiveness.exited;
    _liveness.dispose();
    focusNode.dispose();
    scrollController.dispose();
  }
}

class _CountingTerminal extends Terminal {
  _CountingTerminal() : super(maxLines: 1000);

  int mainBufferReads = 0;

  @override
  Buffer get mainBuffer {
    mainBufferReads++;
    return super.mainBuffer;
  }}
