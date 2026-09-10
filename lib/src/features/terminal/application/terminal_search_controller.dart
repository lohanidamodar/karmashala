import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm2/xterm.dart';

import '../domain/pane_search.dart';
import '../domain/terminal_search.dart';
import '../domain/terminal_search_query.dart';
import 'scrollback_autosave.dart';
import 'terminal_scroll.dart';
import 'terminal_sessions_controller.dart';

/// How the cross-pane sweep is scheduled. Injected because a real `Timer`
/// outlives the widget tree and trips `flutter_test`'s pending-timer check.
class TerminalSearchScheduler {
  const TerminalSearchScheduler({
    this.schedule = _timer,
    this.cancel = _cancelTimer,
  });

  final DelayedSchedule schedule;
  final CancelSchedule cancel;

  static Object _timer(Duration delay, void Function() run) =>
      Timer(delay, run);

  static void _cancelTimer(Object handle) => (handle as Timer).cancel();
}

final terminalSearchSchedulerProvider = Provider<TerminalSearchScheduler>(
  (ref) => const TerminalSearchScheduler(),
);

/// Find state: one query at a time, opened against one pane, optionally
/// reaching the rest of the layout.
class TerminalSearchState {
  const TerminalSearchState({
    this.visible = false,
    this.paneId,
    this.query = '',
    this.caseSensitive = false,
    this.regex = false,
    this.crossPane = false,
    this.patternError,
    this.matchCount = 0,
    this.currentIndex = 0,
    this.currentPaneId,
    this.currentPaneTitle,
    this.truncated = false,
    this.onAlternateScreen = false,
    this.hiddenScrollbackMatches = 0,
    this.panesSearched = 0,
    this.panesPending = 0,
    this.scanning = false,
    this.linesScanned = 0,
  });

  final bool visible;

  /// The pane the bar was opened against — scanned on every keystroke. Not
  /// [currentPaneId], which is wherever the selected hit happens to be.
  final String? paneId;

  final String query;
  final bool caseSensitive;

  /// Whether [query] is a regular expression rather than literal text.
  final bool regex;

  /// Whether every other open pane is searched too.
  final bool crossPane;

  /// Why the pattern would not compile, or null. Set only while [regex] is on;
  /// while it is set nothing matches, deliberately — see [TerminalSearchQuery].
  final String? patternError;

  final int matchCount;

  /// Zero-based index of the highlighted match.
  final int currentIndex;

  /// The pane holding the selected match, and what that pane is called.
  final String? currentPaneId;
  final String? currentPaneTitle;

  /// True when [currentPaneId] holds more than [kMaxSearchHighlights] hits, so
  /// only the first of them are painted.
  final bool truncated;

  /// Whether a full-screen program — `vim`, `htop`, an agent CLI's own UI —
  /// owns the searched pane's screen.
  final bool onAlternateScreen;

  /// Hits *behind* that program: counted, not navigable — the normal buffer
  /// cannot be scrolled to without taking the screen from its owner. Always 0
  /// when [onAlternateScreen] is false, since then it is what is searched.
  final int hiddenScrollbackMatches;

  /// [panesPending] above zero with [scanning] false means the sweep hit
  /// [kCrossPaneMatchBudget] and stopped, which the bar says out loud.
  final int panesSearched;
  final int panesPending;
  final bool scanning;

  /// Buffer lines read since the bar was opened. Published rather than hidden
  /// behind a debug flag because `terminal_search_cost_test.dart` asserts on it.
  final int linesScanned;

  bool get hasMatches => matchCount > 0;

  /// Whether "go to it" would go anywhere.
  bool get currentIsElsewhere =>
      currentPaneId != null && currentPaneId != paneId;

  /// Distinguishes "keep what is there" from "clear it" for the nullable
  /// fields, which `??` cannot express.
  static const _keep = Object();

  TerminalSearchState copyWith({
    bool? visible,
    String? paneId,
    String? query,
    bool? caseSensitive,
    bool? regex,
    bool? crossPane,
    Object? patternError = _keep,
    int? matchCount,
    int? currentIndex,
    Object? currentPaneId = _keep,
    Object? currentPaneTitle = _keep,
    bool? truncated,
    bool? onAlternateScreen,
    int? hiddenScrollbackMatches,
    int? panesSearched,
    int? panesPending,
    bool? scanning,
    int? linesScanned,
  }) {
    return TerminalSearchState(
      visible: visible ?? this.visible,
      paneId: paneId ?? this.paneId,
      query: query ?? this.query,
      caseSensitive: caseSensitive ?? this.caseSensitive,
      regex: regex ?? this.regex,
      crossPane: crossPane ?? this.crossPane,
      patternError: identical(patternError, _keep)
          ? this.patternError
          : patternError as String?,
      matchCount: matchCount ?? this.matchCount,
      currentIndex: currentIndex ?? this.currentIndex,
      currentPaneId: identical(currentPaneId, _keep)
          ? this.currentPaneId
          : currentPaneId as String?,
      currentPaneTitle: identical(currentPaneTitle, _keep)
          ? this.currentPaneTitle
          : currentPaneTitle as String?,
      truncated: truncated ?? this.truncated,
      onAlternateScreen: onAlternateScreen ?? this.onAlternateScreen,
      hiddenScrollbackMatches:
          hiddenScrollbackMatches ?? this.hiddenScrollbackMatches,
      panesSearched: panesSearched ?? this.panesSearched,
      panesPending: panesPending ?? this.panesPending,
      scanning: scanning ?? this.scanning,
      linesScanned: linesScanned ?? this.linesScanned,
    );
  }
}

/// Drives find for the open pane on every keystroke, and sweeps the rest one
/// pane per turn of the event loop — so no keystroke costs more than one scan.
class TerminalSearchController extends Notifier<TerminalSearchState> {
  /// The controller holding this search's highlights, so they can be dropped
  /// when the selection moves to another pane or the bar closes. One reference
  /// is the whole bookkeeping: xterm2 owns the anchors and replaces the set.
  TerminalController? _highlighted;

  /// Every hit, the open pane's first and each swept pane's appended after —
  /// so a sweep landing does not shift the hit the user already has selected.
  List<PaneSearchMatch> _matches = [];

  /// How many of [_matches] came from the sweep, which is what
  /// [kCrossPaneMatchBudget] bounds.
  int _swept = 0;

  /// Panes the armed sweep has still to read, in layout order.
  List<String> _pending = const [];
  Object? _sweepHandle;

  /// The terminal whose buffer switches are being watched, and what it was on
  /// last time we looked. See [_onPaneWrote].
  Terminal? _watched;
  bool _watchedAlternate = false;

  int _linesScanned = 0;

  /// Read up front: `ref` is off limits inside `onDispose`, which is exactly
  /// when an armed sweep has to be cancelled.
  late final TerminalSearchScheduler _scheduler;

  @override
  TerminalSearchState build() {
    _scheduler = ref.read(terminalSearchSchedulerProvider);
    ref.onDispose(() {
      _clearHighlights();
      _watch(null);
      _cancelSweep();
    });
    return const TerminalSearchState();
  }

  /// Opens the find bar against [paneId], starting from a clean query.
  void open(String paneId) {
    _reset();
    state = TerminalSearchState(visible: true, paneId: paneId);
    _watch(_instanceFor(paneId)?.terminal);
  }

  void close() {
    _reset();
    _watch(null);
    state = state.copyWith(
      visible: false,
      query: '',
      patternError: null,
      matchCount: 0,
      currentIndex: 0,
      currentPaneId: null,
      currentPaneTitle: null,
      truncated: false,
      onAlternateScreen: false,
      hiddenScrollbackMatches: 0,
      panesSearched: 0,
      panesPending: 0,
      scanning: false,
      linesScanned: 0,
    );
  }

  void setQuery(String query) {
    state = state.copyWith(query: query);
    _runSearch();
  }

  void toggleCaseSensitive() {
    state = state.copyWith(caseSensitive: !state.caseSensitive);
    _runSearch();
  }

  /// Switches between literal text and a regular expression, keeping the query.
  /// The case toggle composes with it either way — see [TerminalSearchQuery].
  void toggleRegex() {
    state = state.copyWith(regex: !state.regex);
    _runSearch();
  }

  /// Widens the search to every other open pane. Off by default: the expensive
  /// answer is something the user asks for.
  void toggleCrossPane() {
    state = state.copyWith(crossPane: !state.crossPane);
    _runSearch();
  }

  void next() => _step(1);

  void previous() => _step(-1);

  /// Brings the pane holding the selected match to the front and focuses it.
  /// Deliberately not what [next] does: focusing a pane focuses its terminal,
  /// which would take the caret out of the query field mid-word.
  void revealCurrent() {
    final match = _currentMatch();
    if (match == null) return;
    ref
        .read(terminalSessionsControllerProvider.notifier)
        .focusPane(match.paneId);
    _applyHighlights();
    _scrollToCurrent();
  }

  void _reset() {
    _clearHighlights();
    _cancelSweep();
    _matches = [];
    _swept = 0;
    _pending = const [];
    _linesScanned = 0;
  }

  PaneSearchMatch? _currentMatch() {
    final index = state.currentIndex;
    if (index < 0 || index >= _matches.length) return null;
    return _matches[index];
  }

  void _step(int by) {
    if (_matches.isEmpty) return;
    final index = (state.currentIndex + by + _matches.length) % _matches.length;
    state = _describeCurrent(state.copyWith(currentIndex: index), index);
    _applyHighlights();
    _scrollToCurrent();
  }

  /// The three handles the search needs from pane [paneId], or null once it is
  /// closed. A **detached** pane still answers: its process is alive.
  TerminalInstanceRef? _instanceFor(String? paneId) {
    if (paneId == null) return null;
    final instance = ref
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(paneId);
    if (instance == null) return null;
    return (
      terminal: instance.terminal,
      controller: instance.controller,
      scroll: instance.scrollController,
    );
  }

  TerminalSearchQuery _query() => TerminalSearchQuery.parse(
    state.query,
    caseSensitive: state.caseSensitive,
    regex: state.regex,
  );

  /// Fills in everything about the selected hit that the bar shows.
  TerminalSearchState _describeCurrent(TerminalSearchState from, int index) {
    if (index < 0 || index >= _matches.length) {
      return from.copyWith(
        currentPaneId: null,
        currentPaneTitle: null,
        truncated: false,
      );
    }
    final paneId = _matches[index].paneId;
    var inPane = 0;
    for (final match in _matches) {
      if (match.paneId == paneId) inPane++;
    }
    return from.copyWith(
      currentPaneId: paneId,
      currentPaneTitle: ref
          .read(terminalSessionsControllerProvider.notifier)
          .titleForPane(paneId),
      truncated: inPane > kMaxSearchHighlights,
    );
  }

  void _runSearch() {
    _clearHighlights();
    _cancelSweep();
    _swept = 0;
    _pending = const [];

    // Compiled once for the whole scan, and the only place a broken pattern
    // becomes something the bar can say out loud.
    final query = _query();
    final target = _instanceFor(state.paneId);
    if (target == null || !query.isUsable) {
      _matches = [];
      state = _describeCurrent(
        state.copyWith(
          patternError: query.error,
          matchCount: 0,
          currentIndex: 0,
          truncated: false,
          onAlternateScreen: target?.terminal.isUsingAltBuffer ?? false,
          hiddenScrollbackMatches: 0,
          panesSearched: 0,
          panesPending: 0,
          scanning: false,
          linesScanned: _linesScanned,
        ),
        0,
      );
      return;
    }

    // The **active** buffer only: the alternate one keeps its last screen after
    // `\e[?1049l`, so searching it once vim has gone would report hits for text
    // that is on no screen at all.
    final terminal = target.terminal;
    _watchedAlternate = terminal.isUsingAltBuffer;
    final paneId = state.paneId!;
    final found = <PaneSearchMatch>[];
    _linesScanned += _scanPane(
      paneId: paneId,
      terminal: terminal,
      query: query,
      into: found,
    );
    _matches = found;

    state = _describeCurrent(
      state.copyWith(
        patternError: null,
        matchCount: _matches.length,
        currentIndex: 0,
        onAlternateScreen: _watchedAlternate,
        hiddenScrollbackMatches: _watchedAlternate
            ? _countHidden(terminal, query)
            : 0,
        panesSearched: 1,
        panesPending: 0,
        scanning: false,
        linesScanned: _linesScanned,
      ),
      0,
    );
    _applyHighlights();
    _scrollToCurrent();
    _armSweep();
  }

  /// Reads one pane's active buffer into [into], returning the lines it read.
  /// [window] bounds how far back it goes; null — the open pane — means all.
  int _scanPane({
    required String paneId,
    required Terminal terminal,
    required TerminalSearchQuery query,
    required List<PaneSearchMatch> into,
    int? window,
    int? matchBudget,
  }) {
    final lines = terminal.buffer.lines;
    return scanLines(
      query: query,
      lineCount: lines.length,
      firstLine: window == null
          ? 0
          : crossPaneFirstLine(lines.length, window: window),
      lineAt: (index) => lineTextOf(lines[index]),
      matchBudget: matchBudget,
      onMatch: (match) => into.add(
        PaneSearchMatch(paneId: paneId, at: match),
      ),
    );
  }

  /// Arms a sweep of every other pane, replacing whatever was armed. Re-arming
  /// on each keystroke *is* the debounce: six characters pay for one sweep.
  void _armSweep() {
    if (!state.crossPane) return;
    _pending = _otherPanes();
    if (_pending.isEmpty) return;
    state = state.copyWith(panesPending: _pending.length, scanning: true);
    _sweepHandle = _scheduler.schedule(kCrossPaneDebounce, _sweepSlice);
  }

  void _cancelSweep() {
    final handle = _sweepHandle;
    if (handle == null) return;
    _sweepHandle = null;
    _scheduler.cancel(handle);
  }

  /// Every live pane but the one the bar is open against, in layout order. An
  /// empty region has an id and no terminal, so it is dropped rather than
  /// counted towards "searched 4 of 12 panes".
  List<String> _otherPanes() {
    final searched = state.paneId;
    final sessions = ref.read(terminalSessionsControllerProvider);
    final controller = ref.read(terminalSessionsControllerProvider.notifier);
    final ids = <String>[];
    for (final tab in sessions.tabs) {
      for (final paneId in tab.layout.panes) {
        if (paneId == searched) continue;
        if (controller.instanceFor(paneId) == null) continue;
        ids.add(paneId);
      }
    }
    // A detached session is a running process with no tab — a background build
    // or agent, which is exactly the thing worth finding.
    for (final detached in sessions.detached) {
      if (detached.paneId == searched) continue;
      if (controller.instanceFor(detached.paneId) == null) continue;
      ids.add(detached.paneId);
    }
    return ids;
  }

  /// One pane's worth of sweep, then hands the turn back — the unit the cost
  /// gate asserts on: at most [kCrossPaneScanLines] lines per turn.
  void _sweepSlice() {
    _sweepHandle = null;
    if (!state.visible || !state.crossPane) return;
    final query = _query();
    if (!query.isUsable) return;

    if (_pending.isEmpty || _swept >= kCrossPaneMatchBudget) {
      state = state.copyWith(scanning: false);
      return;
    }

    final paneId = _pending.removeAt(0);
    final instance = _instanceFor(paneId);
    final before = _matches.length;
    if (instance != null) {
      final found = <PaneSearchMatch>[];
      _linesScanned += _scanPane(
        paneId: paneId,
        terminal: instance.terminal,
        query: query,
        into: found,
        window: kCrossPaneScanLines,
        matchBudget: kCrossPaneMatchBudget - _swept,
      );
      _swept += found.length;
      _matches.addAll(found);
    }

    final more = _pending.isNotEmpty && _swept < kCrossPaneMatchBudget;
    state = _describeCurrent(
      state.copyWith(
        matchCount: _matches.length,
        panesSearched: state.panesSearched + (instance == null ? 0 : 1),
        panesPending: _pending.length,
        scanning: more,
        linesScanned: _linesScanned,
      ),
      state.currentIndex,
    );
    // Only when this slice found the *first* hit there is; repainting later
    // would fight a user who already has one selected.
    if (before == 0 && _matches.isNotEmpty) {
      _applyHighlights();
      _scrollToCurrent();
    }
    if (more) {
      _sweepHandle = _scheduler.schedule(Duration.zero, _sweepSlice);
    }
  }

  /// Paints up to [kMaxSearchHighlights] hits in the pane holding the current
  /// match — `RenderTerminal` walks every highlight on every frame.
  void _applyHighlights() {
    final match = _currentMatch();
    final target = match == null ? null : _instanceFor(match.paneId);
    if (match == null || target == null) return _clearHighlights();

    // A `CellAnchor` resolves its row against its own buffer, so a hit past the
    // end of this one is dropped rather than anchored elsewhere.
    final buffer = target.terminal.buffer;
    bool paintable(PaneSearchMatch candidate) =>
        candidate.paneId == match.paneId &&
        candidate.at.line < buffer.lines.length;

    // Where the selected hit sits among its pane's paintable ones, and so how
    // many the window must skip to still reach it.
    var before = 0;
    for (var i = 0; i < state.currentIndex; i++) {
      if (paintable(_matches[i])) before++;
    }
    final skip = before < kMaxSearchHighlights
        ? 0
        : before - kMaxSearchHighlights + 1;

    final ranges = <BufferRangeLine>[];
    var seen = 0;
    for (final candidate in _matches) {
      if (!paintable(candidate)) continue;
      if (seen++ < skip) continue;
      ranges.add(
        BufferRangeLine(
          CellOffset(candidate.at.startColumn, candidate.at.line),
          CellOffset(candidate.at.endColumn, candidate.at.line),
        ),
      );
      if (ranges.length >= kMaxSearchHighlights) break;
    }

    // Only for a different pane: `setSearchHighlights` already replaces what
    // this controller holds, in one update.
    if (!identical(_highlighted, target.controller)) _clearHighlights();
    _highlighted = target.controller;
    target.controller.setSearchHighlights(
      buffer,
      ranges,
      currentIndex: before - skip,
    );
  }

  /// How many hits are in the scrollback behind a full-screen program. One
  /// extra pass, only while something owns the screen; the alternative was to
  /// say "No results" and be confidently wrong.
  int _countHidden(Terminal terminal, TerminalSearchQuery query) {
    final lines = terminal.mainBuffer.lines;
    var hidden = 0;
    _linesScanned += scanLines(
      query: query,
      lineCount: lines.length,
      lineAt: (index) => lineTextOf(lines[index]),
      onMatch: (_) => hidden++,
    );
    return hidden;
  }

  /// Watches [terminal] for the moment a program takes or gives back the
  /// screen, and stops watching whatever was watched before.
  void _watch(Terminal? terminal) {
    if (identical(_watched, terminal)) return;
    _watched?.removeListener(_onPaneWrote);
    _watched = terminal;
    _watchedAlternate = terminal?.isUsingAltBuffer ?? false;
    terminal?.addListener(_onPaneWrote);
  }

  /// Runs on every coalesced write to the searched pane, so it is one bool
  /// comparison in the common case. A highlight resolves its row against its
  /// own buffer, so anchors from the scrollback would paint on unrelated rows
  /// of a program's UI the moment that program takes the screen.
  void _onPaneWrote() {
    final terminal = _watched;
    if (terminal == null || terminal.isUsingAltBuffer == _watchedAlternate) {
      return;
    }
    _runSearch();
  }

  void _clearHighlights() {
    _highlighted?.clearSearchHighlights();
    _highlighted = null;
  }

  /// Centres the current match in **its own** pane.
  void _scrollToCurrent() {
    final match = _currentMatch();
    if (match == null) return;
    final target = _instanceFor(match.paneId);
    if (target == null) return;
    scrollTerminalToLine(
      target.scroll,
      line: match.at.line,
      lineCount: target.terminal.buffer.lines.length,
    );
  }
}

/// The three handles the search needs from a live pane.
typedef TerminalInstanceRef = ({
  Terminal terminal,
  TerminalController controller,
  ScrollController scroll,
});

final terminalSearchControllerProvider =
    NotifierProvider<TerminalSearchController, TerminalSearchState>(
      TerminalSearchController.new,
    );
