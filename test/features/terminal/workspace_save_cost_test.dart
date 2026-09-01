import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:chitragupta/src/features/terminal/application/scrollback_autosave.dart';
import 'package:chitragupta/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:chitragupta/src/features/terminal/data/command_block_recorder.dart';
import 'package:chitragupta/src/features/terminal/data/terminal_instance.dart';
import 'package:chitragupta/src/features/terminal/data/terminal_workspace_dao.dart';
import 'package:chitragupta/src/features/terminal/domain/agent_pane_launch.dart';
import 'package:chitragupta/src/features/terminal/domain/pane_layout.dart';
import 'package:chitragupta/src/features/terminal/domain/pane_liveness.dart';
import 'package:chitragupta/src/features/terminal/domain/terminal_profile.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// What a workspace save costs.
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
  late TerminalWorkspaceDao dao;

  setUp(() {
    db = AppDatabase.memory();
    dao = TerminalWorkspaceDao(db);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        scrollbackAutosaveFactoryProvider.overrideWithValue(
          ({required onTick}) => ScrollbackAutosave(
            onTick: onTick,
            schedule: (interval, callback) => Object(),
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
    final second = controller.splitPane(
      SplitAxis.horizontal,
      TerminalProfile.commandPrompt,
    )!;
    return (first, second);
  }

  String storedScrollbackFor(String paneId) {
    for (final tab in dao.loadWorkspace().tabs) {
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

    controller.persistWorkspace();
    final after = [instance(first).encodes, instance(second).encodes];
    expect(after, everyElement(greaterThan(0)));

    controller.persistWorkspace();
    controller.persistWorkspace();

    expect([instance(first).encodes, instance(second).encodes], after);
  });

  test('only the pane that changed is re-encoded', () {
    final (first, second) = twoPanes();
    instance(first).terminal.write('one\r\n');
    instance(second).terminal.write('two\r\n');
    controller.persistWorkspace();
    final quiet = instance(first).encodes;
    final busy = instance(second).encodes;

    instance(second).terminal.write('more\r\n');
    controller.persistWorkspace();

    expect(instance(first).encodes, quiet, reason: 'untouched pane');
    expect(instance(second).encodes, busy + 1, reason: 'pane that wrote');
  });

  test('reusing an encoding never stores stale scrollback', () {
    final (_, second) = twoPanes();
    instance(second).terminal.write('first line\r\n');
    controller.persistWorkspace();
    expect(storedScrollbackFor(second), contains('first line'));

    instance(second).terminal.write('second line\r\n');
    controller.persistWorkspace();

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
    controller.persistWorkspace();

    expect([instance(first).encodes, instance(second).encodes], afterTick);
  });

  test(
    'a pane that never wrote anything is still encoded once, and stored',
    () {
      final (first, _) = twoPanes();
      controller.persistWorkspace();
      expect(instance(first).encodes, 1);
      expect(storedScrollbackFor(first), isEmpty);
    },
  );

  test('a closed pane does not keep its cached encoding alive', () {
    final (first, second) = twoPanes();
    instance(second).terminal.write('two\r\n');
    controller.persistWorkspace();

    controller.closePane(second, detach: false);
    controller.persistWorkspace();

    // The surviving pane is still saved correctly; the closed one is gone.
    expect(dao.loadWorkspace().tabs.single.panes.map((p) => p.id), [first]);
  });

  test('a tick is capped, so its cost does not grow with the number of panes', () {
    // The scale target forbids work proportional to all panes on a timer
    // (docs/ARCHITECTURE.md). A zero budget is the extreme of the same rule:
    // one pane always gets written — progress is guaranteed — and no more.
    controller.openTab(TerminalProfile.powerShell);
    for (var i = 0; i < 5; i++) {
      controller.splitPane(SplitAxis.horizontal, TerminalProfile.powerShell);
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
