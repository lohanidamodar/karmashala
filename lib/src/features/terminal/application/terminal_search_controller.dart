import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../domain/pane_search.dart';
import '../domain/terminal_search.dart';
import '../domain/terminal_search_query.dart';
import 'scrollback_autosave.dart';
import 'terminal_scroll.dart';
import 'terminal_sessions_controller.dart';

/// Colours for search hits. Defaults to the vendored theme's own values; the
/// panel overrides this with the theme it actually paints with.
class TerminalSearchColors {
  const TerminalSearchColors({required this.hit, required this.current});

  final Color hit;
  final Color current;
}

final terminalSearchColorsProvider = Provider<TerminalSearchColors>(
  (ref) => TerminalSearchColors(
    // Translucent so the text underneath stays readable — the highlight is
    // painted over the glyphs, not behind them.
    hit: TerminalThemes.defaultTheme.searchHitBackground.withValues(alpha: 0.4),
    current: TerminalThemes.defaultTheme.searchHitBackgroundCurrent.withValues(
      alpha: 0.5,
    ),
  ),
);

/// How the cross-pane sweep is scheduled.
///
/// Injected for the same two reasons the autosave's scheduler is: a real
/// `Timer` outlives the widget tree and trips `flutter_test`'s pending-timer
/// check, and a cost assertion that had to wait for a real debounce would be a
/// wall-clock assertion by the back door.
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
/// reaching the rest of the workspace.
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

  /// The pane the bar was opened against — the one scanned on every keystroke,
  /// and the one the caret is in. Not the same as [currentPaneId], which is
  /// wherever the selected hit happens to be.
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

  /// Hits in the pane's scrollback that are *behind* that program.
  ///
  /// Counted rather than navigable: they live in the normal buffer, which is
  /// not on screen and cannot be scrolled to without taking the screen away
  /// from the program that owns it. Always 0 when [onAlternateScreen] is false,
  /// because then the scrollback **is** what is being searched.
  final int hiddenScrollbackMatches;

  /// How many panes these results came from, and how many are still to go.
  ///
  /// [panesPending] left above zero with [scanning] false means the sweep hit
  /// [kCrossPaneMatchBudget] and stopped — which the bar says out loud rather
  /// than quietly presenting a partial answer as the whole one.
  final int panesSearched;
  final int panesPending;
  final bool scanning;

  /// Buffer lines read since the bar was opened.
  ///
  /// The search's cost, in the one unit that is worth counting, published
  /// rather than hidden behind a debug flag: `terminal_search_cost_test.dart`
  /// asserts on it, and it is what keeps "search every pane" from quietly
  /// becoming a million line reads per keystroke at the 100-pane target.
  final int linesScanned;

  bool get hasMatches => matchCount > 0;

  /// Whether the selected hit is somewhere other than the pane the bar is open
  /// against — i.e. whether "go to it" means going anywhere.
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

/// Drives find for the pane the bar was opened against, and — when asked — for
/// every other pane in the workspace.
///
/// Highlighting goes through xterm's own `TerminalController.highlight` and
/// `Buffer.createAnchor`, so no vendored file changes: anchors ride along with
/// buffer mutations and detach themselves when their line is evicted from
/// scrollback, which means highlights follow the text and clean up after
/// themselves.
///
/// **The cost shape**, which is the design and not an optimisation
/// (`terminal_search_cost_test.dart` asserts every number in it):
///
/// * The open pane is scanned in full on **every keystroke**. One pane, which
///   is what find has always cost.
/// * Every other pane waits [kCrossPaneDebounce] for the typing to stop, and is
///   then swept **one pane per slice** — one turn of the event loop each —
///   capped at [kCrossPaneScanLines] lines per pane and [kCrossPaneMatchBudget]
///   matches overall.
///
/// So the worst thing one turn of the event loop does is 2 000 line reads, at
/// any number of open panes. Scanning 100 panes' full scrollback on every
/// keypress would have been a million.
class TerminalSearchController extends Notifier<TerminalSearchState> {
  final List<TerminalHighlight> _highlights = [];

  /// Every hit, the open pane's first and each swept pane's appended after —
  /// so a sweep landing does not shift the hit the user already has selected.
  List<PaneSearchMatch> _matches = [];

  /// How many of [_matches] came from the sweep, which is what
  /// [kCrossPaneMatchBudget] bounds.
  int _swept = 0;

  /// Panes the armed sweep has still to read, in workspace order.
  List<String> _pending = const [];
  Object? _sweepHandle;

  /// The terminal whose buffer switches are being watched, and what it was on
  /// last time we looked. See [_onPaneWrote].
  Terminal? _watched;
  bool _watchedAlternate = false;

  int _linesScanned = 0;

  /// Read once, up front: `ref` is off limits inside `onDispose`, and disposal
  /// is exactly when an armed sweep has to be cancelled.
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
  ///
  /// The case toggle keeps working either way — see [TerminalSearchQuery] for
  /// why the two compose rather than one disabling the other.
  void toggleRegex() {
    state = state.copyWith(regex: !state.regex);
    _runSearch();
  }

  /// Widens the search to every other open pane, or narrows it back.
  ///
  /// Off by default, deliberately: with it off the search costs exactly what it
  /// has always cost, and the expensive answer is something the user asks for.
  void toggleCrossPane() {
    state = state.copyWith(crossPane: !state.crossPane);
    _runSearch();
  }

  void next() => _step(1);

  void previous() => _step(-1);

  /// Brings the pane holding the selected match to the front and focuses it.
  ///
  /// Deliberately **not** what [next] does. Focusing a pane focuses its
  /// terminal, which would take the caret out of the query field halfway
  /// through typing a word; stepping paints and scrolls where the hit is, and
  /// going there is a separate, deliberate act.
  void revealCurrent() {
    final match = _currentMatch();
    if (match == null) return;
    ref
        .read(terminalSessionsControllerProvider.notifier)
        .focusPane(match.paneId);
    _applyHighlights();
    _scrollToCurrent();
  }

  // --- internals -------------------------------------------------------------

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

  /// The three handles the search needs from pane [paneId], or null once it has
  /// been closed. A **detached** pane still answers: its process is alive and
  /// its scrollback is worth finding things in.
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

    // Compiled once for the whole scan, and the only place a broken pattern is
    // turned into something the bar can say out loud.
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

    // The **active** buffer, which is the whole point: when a full-screen
    // program owns the screen this is its screen, and when nothing does it is
    // the scrollback. The other one is never searched — the alternate buffer
    // keeps its last screen after `\e[?1049l`, so matching it once vim has
    // gone would report hits for text that is on no screen at all.
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
  ///
  /// [window] bounds how far back it goes; null means all of it, which is what
  /// the open pane gets.
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

  // --- the cross-pane sweep --------------------------------------------------

  /// Arms a sweep of every other pane, replacing whatever was armed.
  ///
  /// Re-arming on each keystroke is the debounce: six characters typed in a row
  /// cancel five sweeps and pay for one.
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

  /// Every live pane but the one the bar is open against, in workspace order.
  ///
  /// Empty split regions have a pane id and no terminal; they are dropped here
  /// so they never count towards "searched 4 of 12 panes".
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
    // A detached session is a pane with no tab and a process still running —
    // a build or an agent left going in the background, which is exactly the
    // thing worth finding.
    for (final detached in sessions.detached) {
      if (detached.paneId == searched) continue;
      if (controller.instanceFor(detached.paneId) == null) continue;
      ids.add(detached.paneId);
    }
    return ids;
  }

  /// One pane's worth of sweep, then hands the turn back.
  ///
  /// The slice is the unit the cost gate asserts on: whatever else is open, one
  /// turn of the event loop reads at most [kCrossPaneScanLines] lines.
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
    // Shown only when this slice found the *first* hit there is — the open pane
    // had none. Any later slice repainting would fight a user who already has
    // one selected.
    if (before == 0 && _matches.isNotEmpty) {
      _applyHighlights();
      _scrollToCurrent();
    }
    if (more) {
      _sweepHandle = _scheduler.schedule(Duration.zero, _sweepSlice);
    }
  }

  // --- painting --------------------------------------------------------------

  /// Paints up to [kMaxSearchHighlights] hits **in the pane holding the current
  /// match**, that one in its own colour.
  ///
  /// Only that pane: `RenderTerminal._paintHighlights` walks every highlight on
  /// every frame, so highlighting all 100 panes at once would put the whole
  /// result set into every pane's frame budget. It is also the only pane whose
  /// buffer the anchors can safely address — a `CellAnchor` resolves its row
  /// against its own buffer.
  void _applyHighlights() {
    _clearHighlights();
    final match = _currentMatch();
    if (match == null) return;
    final target = _instanceFor(match.paneId);
    if (target == null) return;

    final colors = ref.read(terminalSearchColorsProvider);
    final buffer = target.terminal.buffer;
    var painted = 0;
    for (var i = 0; i < _matches.length; i++) {
      if (painted >= kMaxSearchHighlights) break;
      final candidate = _matches[i];
      if (candidate.paneId != match.paneId) continue;
      if (candidate.at.line >= buffer.lines.length) continue;
      painted++;
      _highlights.add(
        target.controller.highlight(
          p1: buffer.createAnchor(candidate.at.startColumn, candidate.at.line),
          p2: buffer.createAnchor(candidate.at.endColumn, candidate.at.line),
          color: i == state.currentIndex ? colors.current : colors.hit,
        ),
      );
    }
  }

  /// How many hits are in the scrollback behind a full-screen program.
  ///
  /// One extra pass over the normal buffer, and only while something owns the
  /// screen — the same scan the search does every keystroke when nothing does,
  /// so the worst case is twice today's cost for the one pane being searched.
  /// It counts into an `int` rather than collecting, so it allocates nothing.
  ///
  /// The alternative was to say "No results" and be confidently wrong: the text
  /// the user is looking for really is in this pane, it is just behind vim.
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

  /// Runs on every coalesced write to the searched pane while the bar is open.
  ///
  /// Deliberately one bool comparison in the common case. It exists because a
  /// highlight's row is resolved against **its own** buffer: anchors taken from
  /// the scrollback would paint on unrelated rows of a program's UI the moment
  /// that program takes the screen, so the search is re-run — which drops them
  /// — rather than left pointing at a buffer nobody is looking at.
  void _onPaneWrote() {
    final terminal = _watched;
    if (terminal == null || terminal.isUsingAltBuffer == _watchedAlternate) {
      return;
    }
    _runSearch();
  }

  void _clearHighlights() {
    for (final highlight in _highlights) {
      highlight.dispose();
    }
    _highlights.clear();
  }

  /// Centres the current match in **its own** pane, using the same
  /// line-to-offset helper command navigation uses.
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
