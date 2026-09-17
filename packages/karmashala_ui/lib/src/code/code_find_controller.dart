import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:re_editor/re_editor.dart';

import '../design_tokens.dart';
import 'code_search.dart';

/// Buffers at least this long are searched off the UI isolate.
const int kCodeSearchOffThreadChars = 256 * 1024;

/// Past this many matches only the ones near the viewport are handed to the
/// editor to paint; below it, all of them.
const int kCodeHighlightAllBelow = 2000;

/// `re_editor`'s find, driven by the app's matcher.
///
/// The editor keeps everything it does with a find controller — the overlay
/// slot, match painting, selecting and scrolling to the current match, Esc and
/// the focus hand-back, the find/replace intents, and replace as one undo
/// step. Only the matching is replaced: the built-in maps every match by
/// walking the lines from the top and queues one isolate search per keystroke
/// with no cancelling, which took 6.8 s for 50,000 matches in a 50,000-line
/// buffer. This one is linear, debounced, drops stale results, adds whole
/// word, and reports a bad regex instead of finding nothing.
class AppCodeFindController extends ValueNotifier<CodeFindValue?>
    implements CodeFindController {
  AppCodeFindController(
    this._editing, {
    this.debounce = Latency.searchDebounce,
    this.offThreadChars = kCodeSearchOffThreadChars,
  }) : super(null) {
    _editing.addListener(_onBufferChanged);
    findInputController.addListener(_onQueryChanged);
  }

  final CodeLineEditingController _editing;
  final Duration debounce;
  final int offThreadChars;

  @override
  final TextEditingController findInputController = TextEditingController();
  @override
  final TextEditingController replaceInputController = TextEditingController();
  @override
  final FocusNode findInputFocusNode = FocusNode(debugLabel: 'find');
  @override
  final FocusNode replaceInputFocusNode = FocusNode(debugLabel: 'replace');

  /// Replace refuses in a read-only buffer, whatever asks.
  bool readOnly = false;

  bool _caseSensitive = false;
  bool _regex = false;
  bool _wholeWord = false;
  String? _patternError;
  Timer? _timer;
  int _generation = 0;
  bool _disposed = false;

  /// The buffer the current result was found in; any other means stale.
  CodeLines? _searched;

  int _windowStart = 0;
  int _windowEnd = -1;
  List<CodeLineSelection>? _highlights;
  CodeFindResult? _highlightsFor;

  bool get isOpen => value != null;
  bool get caseSensitive => _caseSensitive;
  bool get regex => _regex;
  bool get wholeWord => _wholeWord;
  bool get replaceShown => (value?.replaceMode ?? false) && !readOnly;

  /// The compiler's reason the query is not a pattern, or null.
  String? get patternError => _patternError;

  /// True from a change to the query or the buffer until its result lands.
  bool get isSearching =>
      (value?.searching ?? false) || (_timer?.isActive ?? false) || _isStale;

  bool get _isStale {
    final result = value?.result;
    return result != null &&
        (result.dirty || !identical(_searched, _editing.codeLines));
  }

  /// Matches in the latest settled result; 0 while there is none.
  int get matchCount => _isStale ? 0 : value?.result?.matches.length ?? 0;

  /// The current match, 0-based, or null.
  int? get currentIndex {
    final result = value?.result;
    if (result == null || _isStale) return null;
    return result.index;
  }

  @override
  List<CodeLineSelection>? get allMatchSelections {
    final result = value?.result;
    if (result == null || _isStale) return null;
    if (identical(result, _highlightsFor)) return _highlights;
    final matches = result.matches;
    final Iterable<CodeLineSelection> wanted;
    if (matches.length < kCodeHighlightAllBelow || matches is! CodeMatchList) {
      wanted = matches;
    } else {
      final from = matches.firstAtOrAfter(_windowStart, 0);
      final to = matches.firstAtOrAfter(_windowEnd + 1, 0);
      wanted = [for (var i = from; i < to; i++) matches[i]];
    }
    _highlightsFor = result;
    return _highlights = [
      for (final match in wanted) ?convertMatchToSelection(match),
    ];
  }

  @override
  CodeLineSelection? get currentMatchSelection {
    final match = value?.result?.currentMatch;
    if (match == null || _isStale) return null;
    return convertMatchToSelection(match);
  }

  /// Tells the controller which lines are on screen. True when the painted
  /// highlights no longer cover them and the editor has to be rebuilt.
  bool showLines(int first, int last) {
    if (first >= _windowStart && last <= _windowEnd) return false;
    final span = math.max(200, (last - first) * 2);
    _windowStart = math.max(0, first - span);
    _windowEnd = last + span;
    _highlightsFor = null;
    return (value?.result?.matches.length ?? 0) >= kCodeHighlightAllBelow;
  }

  @override
  void findMode() => _open(replace: false);

  @override
  void replaceMode() => _open(replace: !readOnly);

  void _open({required bool replace}) {
    final selection = _editing.selection;
    final prefill = !selection.isCollapsed && selection.isSameLine
        ? _editing.selectedText
        : null;
    value = CodeFindValue(
      option: CodeFindOption(
        pattern: prefill ?? findInputController.text,
        caseSensitive: _caseSensitive,
        regex: _regex,
      ),
      replaceMode: replace,
      searching: true,
    );
    if (prefill != null) {
      findInputController.value = TextEditingValue(
        text: prefill,
        selection: TextSelection(baseOffset: 0, extentOffset: prefill.length),
      );
    } else {
      findInputController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: findInputController.text.length,
      );
    }
    final replaceFirst = replace && findInputController.text.isNotEmpty;
    (replaceFirst ? replaceInputFocusNode : findInputFocusNode).requestFocus();
    if (replaceFirst) {
      replaceInputController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: replaceInputController.text.length,
      );
    }
    _search(now: true);
  }

  @override
  void focusOnFindInput() {
    findInputFocusNode.requestFocus();
    findInputController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: findInputController.text.length,
    );
  }

  @override
  void focusOnReplaceInput() {
    replaceInputFocusNode.requestFocus();
    replaceInputController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: replaceInputController.text.length,
    );
  }

  @override
  void toggleMode() {
    final current = value;
    if (current == null || readOnly) return;
    value = current.copyWith(
      replaceMode: !current.replaceMode,
      result: current.result,
    );
  }

  @override
  void close() {
    _timer?.cancel();
    _generation++;
    value = null;
  }

  @override
  void toggleRegex() {
    _regex = !_regex;
    _optionsChanged();
  }

  @override
  void toggleCaseSensitive() {
    _caseSensitive = !_caseSensitive;
    _optionsChanged();
  }

  void toggleWholeWord() {
    _wholeWord = !_wholeWord;
    _optionsChanged();
  }

  void _optionsChanged() {
    final current = value;
    if (current == null) return;
    value = current.copyWith(
      option: current.option.copyWith(
        caseSensitive: _caseSensitive,
        regex: _regex,
      ),
      result: current.result?.copyWith(dirty: true),
      searching: true,
    );
    _search(now: true);
  }

  @override
  void nextMatch() => _step(forward: true);

  @override
  void previousMatch() => _step(forward: false);

  void _step({required bool forward}) {
    _flush();
    final current = value;
    final result = current?.result;
    if (current == null || result == null || _isStale) return;
    value = current.copyWith(result: forward ? result.next : result.previous);
    _reveal();
  }

  /// Selects the current match and scrolls to it. The editor does this itself
  /// only while it is not focused, and F3 is pressed from inside it.
  void _reveal() {
    final selection = currentMatchSelection;
    if (selection == null) return;
    _editing.selection = selection;
    _editing.makePositionCenterIfInvisible(selection.start);
  }

  @override
  void replaceMatch() {
    if (readOnly) return;
    _flush();
    final selection = currentMatchSelection;
    if (selection == null) return;
    _editing.replaceSelection(replaceInputController.text, selection);
    _search(now: true);
  }

  @override
  void replaceAllMatches() {
    if (readOnly) return;
    _flush();
    final current = value;
    if (current == null || matchCount == 0) return;
    final RegExp? pattern;
    try {
      pattern = codeSearchPattern(
        current.option.pattern,
        caseSensitive: _caseSensitive,
        regex: _regex,
        wholeWord: _wholeWord,
      );
    } on FormatException {
      return;
    }
    if (pattern == null) return;
    // One revocable op inside `replaceAll`, so one undo puts every match back.
    _editing.replaceAll(_NonEmptyMatches(pattern), replaceInputController.text);
    _search(now: true);
  }

  @override
  CodeLineSelection? convertMatchToSelection(CodeLineSelection match) {
    final base = _editing.lineIndex2Index(match.baseIndex);
    if (base.chunkIndex >= 0) return null;
    final extent = match.isSameLine
        ? base
        : _editing.lineIndex2Index(match.extentIndex);
    if (extent.chunkIndex >= 0) return null;
    return match.copyWith(baseIndex: base.index, extentIndex: extent.index);
  }

  void _onQueryChanged() {
    final current = value;
    if (current == null) return;
    final query = findInputController.text;
    if (query == current.option.pattern) return;
    value = current.copyWith(
      option: current.option.copyWith(pattern: query),
      result: current.result?.copyWith(dirty: true),
      searching: true,
    );
    _search();
  }

  /// A keystroke or a reload. Not notified here: the buffer can change while a
  /// tab is building, and the stale check already hides the old highlights.
  void _onBufferChanged() {
    if (value == null || identical(_searched, _editing.codeLines)) return;
    if (_timer?.isActive ?? false) return;
    _search();
  }

  /// Runs a search queued behind the debounce now, so a step or a replace
  /// acts on the query as typed rather than as it was a moment ago.
  void _flush() {
    if (_timer?.isActive ?? false) _search(now: true);
  }

  void _search({bool now = false}) {
    _timer?.cancel();
    if (!now) {
      _timer = Timer(debounce, () => _search(now: true));
      return;
    }
    final current = value;
    if (current == null) return;
    final generation = ++_generation;
    final query = current.option.pattern;
    final lines = _editing.codeLines;
    _patternError = codeSearchPatternError(
      query,
      caseSensitive: _caseSensitive,
      regex: _regex,
      wholeWord: _wholeWord,
    );
    if (query.isEmpty || _patternError != null) {
      _searched = lines;
      value = current.copyWith(result: null, searching: false);
      return;
    }
    final request = CodeSearchRequest(
      text: lines.asString(TextLineBreak.lf),
      query: query,
      caseSensitive: _caseSensitive,
      regex: _regex,
      wholeWord: _wholeWord,
    );
    if (request.text.length < offThreadChars) {
      _land(generation, lines, findCodeMatches(request));
      return;
    }
    compute(findCodeMatches, request).then(
      (flat) => _land(generation, lines, flat),
      onError: (Object _) => _land(generation, lines, Int32List(0)),
    );
  }

  void _land(int generation, CodeLines lines, Int32List flat) {
    final current = value;
    if (_disposed || current == null || generation != _generation) return;
    _searched = lines;
    final matches = CodeMatchList(flat);
    if (matches.isEmpty) {
      value = current.copyWith(result: null, searching: false);
      return;
    }
    // The first match at or after the caret, so stepping starts where the
    // reader is, and wraps to the top past the last.
    final caret = _editing.selection.start;
    final at = matches.firstAtOrAfter(caret.index, caret.offset);
    value = current.copyWith(
      result: CodeFindResult(
        index: at == matches.length ? 0 : at,
        matches: matches,
        option: current.option,
        codeLines: lines,
        dirty: false,
      ),
      searching: false,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _editing.removeListener(_onBufferChanged);
    findInputController
      ..removeListener(_onQueryChanged)
      ..dispose();
    replaceInputController.dispose();
    findInputFocusNode.dispose();
    replaceInputFocusNode.dispose();
    super.dispose();
  }
}

/// [pattern] without its empty matches, which the search never shows and a
/// replace must not insert at.
class _NonEmptyMatches implements Pattern {
  const _NonEmptyMatches(this.pattern);

  final RegExp pattern;

  @override
  Iterable<Match> allMatches(String string, [int start = 0]) => pattern
      .allMatches(string, start)
      .where((match) => match.end > match.start);

  @override
  Match? matchAsPrefix(String string, [int start = 0]) {
    final match = pattern.matchAsPrefix(string, start);
    return match == null || match.end == match.start ? null : match;
  }
}
