import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../domain/terminal_search.dart';
import '../domain/terminal_search_query.dart';
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

/// Find-in-scrollback state. One search at a time, targeting one pane, as in
/// VS Code's terminal.
class TerminalSearchState {
  const TerminalSearchState({
    this.visible = false,
    this.paneId,
    this.query = '',
    this.caseSensitive = false,
    this.regex = false,
    this.patternError,
    this.matchCount = 0,
    this.currentIndex = 0,
    this.truncated = false,
  });

  final bool visible;
  final String? paneId;
  final String query;
  final bool caseSensitive;

  /// Whether [query] is a regular expression rather than literal text.
  final bool regex;

  /// Why the pattern would not compile, or null. Set only while [regex] is on;
  /// while it is set nothing matches, deliberately — see [TerminalSearchQuery].
  final String? patternError;

  final int matchCount;

  /// Zero-based index of the highlighted match.
  final int currentIndex;

  /// True when there were more matches than [kMaxSearchHighlights] to paint.
  final bool truncated;

  bool get hasMatches => matchCount > 0;

  /// Distinguishes "keep what is there" from "clear it" for the one nullable
  /// field, which `??` cannot express.
  static const _keep = Object();

  TerminalSearchState copyWith({
    bool? visible,
    String? paneId,
    String? query,
    bool? caseSensitive,
    bool? regex,
    Object? patternError = _keep,
    int? matchCount,
    int? currentIndex,
    bool? truncated,
  }) {
    return TerminalSearchState(
      visible: visible ?? this.visible,
      paneId: paneId ?? this.paneId,
      query: query ?? this.query,
      caseSensitive: caseSensitive ?? this.caseSensitive,
      regex: regex ?? this.regex,
      patternError: identical(patternError, _keep)
          ? this.patternError
          : patternError as String?,
      matchCount: matchCount ?? this.matchCount,
      currentIndex: currentIndex ?? this.currentIndex,
      truncated: truncated ?? this.truncated,
    );
  }
}

/// Drives find-in-scrollback for the focused pane.
///
/// Highlighting goes through xterm's own `TerminalController.highlight` and
/// `Buffer.createAnchor`, so no vendored file changes: anchors ride along with
/// buffer mutations and detach themselves when their line is evicted from
/// scrollback, which means highlights follow the text and clean up after
/// themselves.
class TerminalSearchController extends Notifier<TerminalSearchState> {
  final List<TerminalHighlight> _highlights = [];
  List<ScrollbackMatch> _matches = const [];

  @override
  TerminalSearchState build() {
    ref.onDispose(_clearHighlights);
    return const TerminalSearchState();
  }

  /// Opens the find bar against [paneId], starting from a clean query.
  void open(String paneId) {
    _clearHighlights();
    _matches = const [];
    state = TerminalSearchState(visible: true, paneId: paneId);
  }

  void close() {
    _clearHighlights();
    _matches = const [];
    state = state.copyWith(
      visible: false,
      query: '',
      patternError: null,
      matchCount: 0,
      currentIndex: 0,
      truncated: false,
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

  void next() => _step(1);

  void previous() => _step(-1);

  // --- internals -------------------------------------------------------------

  void _step(int by) {
    if (_matches.isEmpty) return;
    final index = (state.currentIndex + by + _matches.length) % _matches.length;
    state = state.copyWith(currentIndex: index);
    _applyHighlights();
    _scrollToCurrent();
  }

  TerminalInstanceRef? _target() {
    final paneId = state.paneId;
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

  void _runSearch() {
    _clearHighlights();
    // Compiled once for the whole scan, and the only place a broken pattern is
    // turned into something the bar can say out loud.
    final query = TerminalSearchQuery.parse(
      state.query,
      caseSensitive: state.caseSensitive,
      regex: state.regex,
    );
    final target = _target();
    if (target == null || !query.isUsable) {
      _matches = const [];
      state = state.copyWith(
        patternError: query.error,
        matchCount: 0,
        currentIndex: 0,
        truncated: false,
      );
      return;
    }

    final lines = target.terminal.buffer.lines;
    final found = <ScrollbackMatch>[];
    scanLines(
      query: query,
      lineCount: lines.length,
      lineAt: (index) => lineTextOf(lines[index]),
      onMatch: found.add,
    );
    _matches = found;

    state = state.copyWith(
      patternError: null,
      matchCount: _matches.length,
      currentIndex: 0,
      truncated: _matches.length > kMaxSearchHighlights,
    );
    _applyHighlights();
    _scrollToCurrent();
  }

  /// Paints up to [kMaxSearchHighlights] hits, the current one in its own
  /// colour.
  ///
  /// The cap is not cosmetic: `RenderTerminal._paintHighlights` walks every
  /// highlight on every frame, so an uncapped search over a 10 000-line buffer
  /// would put thousands of iterations into each frame.
  void _applyHighlights() {
    _clearHighlights();
    final target = _target();
    if (target == null || _matches.isEmpty) return;

    final colors = ref.read(terminalSearchColorsProvider);
    final buffer = target.terminal.buffer;
    final limit = _matches.length < kMaxSearchHighlights
        ? _matches.length
        : kMaxSearchHighlights;

    for (var i = 0; i < limit; i++) {
      final match = _matches[i];
      if (match.line >= buffer.lines.length) continue;
      _highlights.add(
        target.controller.highlight(
          p1: buffer.createAnchor(match.startColumn, match.line),
          p2: buffer.createAnchor(match.endColumn, match.line),
          color: i == state.currentIndex ? colors.current : colors.hit,
        ),
      );
    }
  }

  void _clearHighlights() {
    for (final highlight in _highlights) {
      highlight.dispose();
    }
    _highlights.clear();
  }

  /// Centres the current match in its pane, using the same line-to-offset
  /// helper command navigation uses.
  void _scrollToCurrent() {
    if (_matches.isEmpty) return;
    final target = _target();
    if (target == null) return;
    scrollTerminalToLine(
      target.scroll,
      line: _matches[state.currentIndex].line,
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
