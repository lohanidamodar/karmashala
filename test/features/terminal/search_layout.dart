import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala/src/features/terminal/application/terminal_search_controller.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/data/terminal_instance.dart';
import 'package:karmashala/src/features/terminal/domain/agent_pane_launch.dart';
import 'package:karmashala/src/features/terminal/domain/pane_search.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';
import 'package:xterm/xterm.dart';

import 'fake_instance.dart';

/// A scheduler with no clock: it records what the search armed and fires it
/// only when a test says so.
///
/// A real `Timer` here would make the cost assertions wall-clock dependent —
/// exactly what the counted-not-timed rule exists to avoid — and would outlive
/// the container in every test that opened the bar.
class ManualSearchSchedule {
  final _pending = <Object, void Function()>{};

  /// How many callbacks have actually run — the number of *slices* a sweep
  /// took.
  int fired = 0;

  int get pendingCount => _pending.length;

  Object schedule(Duration delay, void Function() run) {
    final handle = Object();
    _pending[handle] = run;
    return handle;
  }

  void cancel(Object handle) => _pending.remove(handle);

  /// Runs exactly one armed callback, so a test can measure what one turn of
  /// the event loop costs. Returns false when nothing was armed.
  bool step() {
    if (_pending.isEmpty) return false;
    final entry = _pending.entries.first;
    _pending.remove(entry.key);
    fired++;
    entry.value();
    return true;
  }

  /// Runs armed callbacks until none are left, returning how many ran.
  int drain() {
    var slices = 0;
    // Bounded so a scheduler that re-arms itself forever fails the test rather
    // than hanging the suite.
    while (slices < 10000 && step()) {
      slices++;
    }
    return slices;
  }
}

/// A workspace of [panes] tabs, each holding one pane whose terminal carries
/// [linesPerPane] lines of history.
///
/// Panes are their own tabs rather than splits so every pane is addressable and
/// none of them is on screen but the first — which is the shape the cost
/// assertions care about.
class SearchLayout {
  SearchLayout._(this.container, this.sessions, this.panes, this.schedule);

  factory SearchLayout({
    int panes = 12,
    int linesPerPane = 2500,
    String Function(int pane, int line)? text,
  }) {
    final schedule = ManualSearchSchedule();
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(instanceFactory: _bigTerminals),
        terminalSearchSchedulerProvider.overrideWithValue(
          TerminalSearchScheduler(
            schedule: schedule.schedule,
            cancel: schedule.cancel,
          ),
        ),
      ],
    );
    final sessions = container.read(terminalSessionsControllerProvider.notifier);
    final ids = <String>[];
    for (var pane = 0; pane < panes; pane++) {
      sessions.openTab(TerminalProfile.powerShell);
      final id = container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .layout
          .panes
          .single;
      ids.add(id);
      // One write per pane, not one per line: the parser is the slow part of
      // building the fixture and this is not what is being measured.
      sessions.instanceFor(id)!.terminal.write(
        [
          for (var line = 0; line < linesPerPane; line++)
            text?.call(pane, line) ?? 'pane $pane line $line',
        ].join('\r\n'),
      );
    }
    return SearchLayout._(container, sessions, ids, schedule);
  }

  final ProviderContainer container;
  final TerminalSessionsController sessions;
  final List<String> panes;
  final ManualSearchSchedule schedule;

  TerminalSearchController get search =>
      container.read(terminalSearchControllerProvider.notifier);

  TerminalSearchState get state =>
      container.read(terminalSearchControllerProvider);

  /// How many lines a pane's active buffer actually holds — the unit every cost
  /// assertion is written in, read from the terminal rather than assumed.
  int lineCount(String paneId) =>
      sessions.instanceFor(paneId)!.terminal.buffer.lines.length;

  /// The id of the tab holding [paneId].
  String tabOf(String paneId) => container
      .read(terminalSessionsControllerProvider)
      .tabs
      .firstWhere((tab) => tab.layout.panes.contains(paneId))
      .id;

  void write(String paneId, String text) =>
      sessions.instanceFor(paneId)!.terminal.write(text);

  void dispose() => container.dispose();
}

/// Panes big enough to be worth bounding: the default fake caps at 1000 lines,
/// which is under [kCrossPaneScanLines] and would hide the bound.
TerminalInstance _bigTerminals({
  required String id,
  required TerminalProfile profile,
  String? workingDirectory,
  String? restoredScrollback,
  bool shellIntegration = false,
  AgentPaneLaunch? agentLaunch,
  Terminal? adoptTerminal,
}) => FakeTerminalInstance(
  id: id,
  title: profile.label,
  profileId: profile.id,
  workingDirectory: workingDirectory,
  adoptTerminal: Terminal(maxLines: 20000)..resize(80, 24),
);
