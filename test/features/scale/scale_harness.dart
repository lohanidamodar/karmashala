import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/terminal/application/scrollback_autosave.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:xterm2/xterm.dart';

import '../terminal/fake_instance.dart';

/// Shared counting scaffolding for the scale gates in this directory.
///
/// Every one of them obeys the same house rule the four cost tests it was
/// modelled on state: **count work, never time it.** The suite runs at
/// `--concurrency=4` beside other work, so a wall-clock assertion over a few
/// milliseconds is a coin toss, and the units that actually matter here —
/// database statements, buffer reads, listeners, live instances — are all
/// countable directly.

/// An [AppDatabase] that records every statement issued through its public
/// helpers, so a period of the app's life can be priced in statements.
///
/// Schema migration runs against the raw handle inside `AppDatabase`'s own
/// constructor and is therefore not counted, which is what makes a freshly
/// opened counter read zero.
class CountingDatabase extends AppDatabase {
  CountingDatabase() : super(sqlite3.openInMemory());

  final List<String> statements = [];

  void reset() => statements.clear();

  int get count => statements.length;

  static bool _isRead(String sql) =>
      sql.trimLeft().toUpperCase().startsWith('SELECT');

  List<String> get reads => statements.where(_isRead).toList();

  List<String> get writes =>
      statements.where((sql) => !_isRead(sql)).toList();

  @override
  List<Map<String, Object?>> query(
    String sql, [
    List<Object?> params = const [],
  ]) {
    statements.add(sql);
    return super.query(sql, params);
  }

  @override
  void execute(String sql, [List<Object?> params = const []]) {
    statements.add(sql);
    super.execute(sql, params);
  }
}

/// A terminal that counts what reads its buffer and what listens to it.
///
/// `mainBuffer` is the scrollback codec's single entry point into the buffer —
/// it reads the getter once per `encodeScrollback` call — so [bufferReads] is
/// the encode count, the same unit `layout_save_cost_test` uses.
///
/// `listeners` is a plain public field on xterm's `Observable`, so the live
/// listener count needs nothing added to the app to be observed.
class CountingTerminal extends Terminal {
  CountingTerminal({super.maxLines = 1000});

  int bufferReads = 0;

  int get listenerCount => listeners.length;

  @override
  Buffer get mainBuffer {
    bufferReads++;
    return super.mainBuffer;
  }
}

/// A scheduler with no clock: it records what was armed and fires it only when
/// a test says so.
///
/// The same seam `layout_save_cost_test` records the autosave's cadence
/// through, plus the ability to actually run the tick — which is what makes a
/// soak of a stated length in *app* time cost nothing in wall time.
class RecordedSchedule {
  final Map<Object, void Function()> _live = {};

  /// Every delay ever armed, in order.
  final List<Duration> delays = [];

  /// How many callbacks have run.
  int fired = 0;

  /// Timers currently outstanding. One, for the whole app, is the claim.
  int get pending => _live.length;

  Object schedule(Duration delay, void Function() run) {
    delays.add(delay);
    final handle = Object();
    _live[handle] = run;
    return handle;
  }

  void cancel(Object handle) => _live.remove(handle);

  /// Runs one armed callback. Returns false when nothing was armed.
  bool fire() {
    if (_live.isEmpty) return false;
    final entry = _live.entries.first;
    _live.remove(entry.key);
    fired++;
    entry.value();
    return true;
  }

  /// Runs [times] ticks, stopping early if the app ever stops re-arming.
  int fireTimes(int times) {
    var ran = 0;
    while (ran < times && fire()) {
      ran++;
    }
    return ran;
  }
}

/// A layout of process-free panes over a real database, driven through the
/// production [TerminalSessionsController].
///
/// One pane per tab rather than splits: every pane is then addressable, and the
/// per-tab costs (a stored row, a label, a tier) are all in the measurement.
class ScaleLayout {
  ScaleLayout._(
    this.container,
    this.controller,
    this.database,
    this.schedule,
    this.terminalsByPane,
    this.instancesByPane,
  );

  factory ScaleLayout({AppDatabase? database}) {
    final db = database ?? CountingDatabase();
    final schedule = RecordedSchedule();
    final terminals = <String, CountingTerminal>{};
    final instances = <String, FakeTerminalInstance>{};
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        scrollbackAutosaveFactoryProvider.overrideWithValue(
          ({required onTick}) => ScrollbackAutosave(
            onTick: onTick,
            schedule: schedule.schedule,
            cancel: schedule.cancel,
          ),
        ),
        shellIntegrationEnabledProvider.overrideWithValue(false),
        restoreLivePanesProvider.overrideWithValue(true),
        terminalInstanceFactoryProvider.overrideWithValue(
          ({
            required id,
            required profile,
            workingDirectory,
            restoredScrollback,
            shellIntegration = false,
            agentLaunch,
            adoptTerminal,
          }) {
            final terminal = CountingTerminal()..resize(120, 40);
            if (restoredScrollback != null && restoredScrollback.isNotEmpty) {
              terminal.write(restoredScrollback);
            }
            terminals[id] = terminal;
            return instances[id] = FakeTerminalInstance(
              id: id,
              title: agentLaunch?.title ?? agentLaunch?.agentId ?? profile.label,
              profileId: agentLaunch?.profileId ?? profile.id,
              workingDirectory: workingDirectory,
              agentLaunch: agentLaunch,
              // Handed the buffer rather than the text: the pane then counts
              // every read of it, including the ones the restore did.
              adoptTerminal: terminal,
            );
          },
        ),
      ],
    );
    return ScaleLayout._(
      container,
      container.read(terminalSessionsControllerProvider.notifier),
      db,
      schedule,
      terminals,
      instances,
    );
  }

  final ProviderContainer container;
  final TerminalSessionsController controller;
  final AppDatabase database;
  final RecordedSchedule schedule;

  /// Every terminal the factory has ever built, by pane id — including panes
  /// that have since been closed, which is what makes a leak visible.
  final Map<String, CountingTerminal> terminalsByPane;

  /// Every pane the factory has ever built, by pane id — closed ones included,
  /// so a pane that was never disposed is countable.
  final Map<String, FakeTerminalInstance> instancesByPane;

  /// Panes that were built and never disposed. Equal to the number of live
  /// panes, or something is holding a terminal open.
  int get undisposedPanes =>
      instancesByPane.values.where((pane) => !pane.disposed).length;

  /// Listeners still attached to every terminal ever built. The controller
  /// attaches two per live pane (dirty tracking and liveness) and `_unlisten`
  /// exists to take them off again.
  int get liveTerminalListeners => terminalsByPane.values.fold(
    0,
    (sum, terminal) => sum + terminal.listenerCount,
  );

  TerminalSessionsState get state =>
      container.read(terminalSessionsControllerProvider);

  CountingDatabase get counting => database as CountingDatabase;

  /// Opens a tab holding one pane and returns that pane's id.
  String openPane() {
    final tabId = controller.openTab(TerminalProfile.powerShell);
    return state.tabs.firstWhere((tab) => tab.id == tabId).layout.panes.single;
  }

  /// Fills [paneId] with [lines] lines of colourised output — the kind of text
  /// that makes a stored scrollback big enough for its encoding to matter.
  void fill(String paneId, {int lines = 200}) {
    controller.instanceFor(paneId)!.terminal.write(
      [
        for (var i = 0; i < lines; i++)
          '\x1b[38;5;${(i % 200) + 16}m*\x1b[0m \x1b[1mUpdate\x1b[0m('
              'lib/src/features/terminal/data/file_$i.dart)  '
              '\x1b[2m+${i % 40} -${i % 7}\x1b[0m',
      ].join('\r\n'),
    );
  }

  /// Opens [count] filled panes and returns their ids.
  List<String> openPanes(int count, {int linesPerPane = 200}) {
    final ids = <String>[];
    for (var i = 0; i < count; i++) {
      final id = openPane();
      fill(id, lines: linesPerPane);
      ids.add(id);
    }
    return ids;
  }

  /// Writes everything that is owed and leaves nothing dirty — the state a
  /// layout nobody is typing into settles into within a second of the last
  /// keystroke.
  void settle() {
    controller.saveDirtyScrollback(budget: const Duration(minutes: 1));
    controller.persistLayout();
  }

  /// What the store currently holds for [paneId] — read back through SQL
  /// rather than through the dao, so a dao that skipped a write it thought it
  /// had made cannot hide it.
  String storedScrollback(String paneId) {
    final rows = database.query(
      'SELECT scrollback FROM terminal_panes WHERE id = ?;',
      [paneId],
    );
    return rows.isEmpty ? '' : rows.first['scrollback']! as String;
  }

  int get storedPaneRows =>
      database.query('SELECT COUNT(*) AS n FROM terminal_panes;').first['n']!
          as int;

  int get storedTabRows =>
      database.query('SELECT COUNT(*) AS n FROM terminal_tabs;').first['n']!
          as int;

  /// The copy a save takes when it loses something. Bounded rather than
  /// growing: each backup replaces the last.
  int get backupTabRows =>
      database
              .query('SELECT COUNT(*) AS n FROM terminal_tabs_backup;')
              .first['n']!
          as int;

  int get backupPaneRows =>
      database
              .query('SELECT COUNT(*) AS n FROM terminal_panes_backup;')
              .first['n']!
          as int;

  void dispose() {
    container.dispose();
    database.close();
  }
}
