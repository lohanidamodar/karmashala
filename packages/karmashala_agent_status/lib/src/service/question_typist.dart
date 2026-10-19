import 'dart:math' as math;

import 'package:agent_cli/descriptors.dart';

import '../domain/prompt_refusal.dart';

/// Answers Claude Code's `AskUserQuestion` by driving its screen and checking
/// every step lands before the next: the tab is drawn, the highlight reached
/// the row, the box is ticked, the words are typed, the next tab or the review
/// appeared. Neither one burst nor fixed pauses survived the real app — keys
/// sent while a tab draws are dropped. A step that cannot be
/// seen to land stops the answer with [SessionPromptRefusal].
class SessionQuestionTypist {
  SessionQuestionTypist({
    required this.readScreen,
    required this.press,
    this.poll = const Duration(milliseconds: 50),
    this.stepPatience = const Duration(milliseconds: 1200),
    this.screenPatience = const Duration(seconds: 8),
    this.settle = const Duration(milliseconds: 300),
  });

  /// The bottom rows of the session's pane, or null without one.
  final List<String>? Function(String sessionId) readScreen;

  /// Presses keys in the session's pane; false without one.
  final bool Function(String sessionId, String keys) press;

  final Duration poll;

  /// How long one arrow may take to show before it is pressed again.
  final Duration stepPatience;

  /// How long a tab, a tick or the review may take to appear.
  final Duration screenPatience;

  /// A pause once a new tab is drawn, before its first key.
  final Duration settle;

  static const _down = '\x1b[B';
  static const _up = '\x1b[A';
  // Claude Code's `tabs:next` and `tabs:previous`. Not Tab and Shift+Tab:
  // were the question gone, Shift+Tab would change the permission mode.
  static const _right = '\x1b[C';
  static const _left = '\x1b[D';
  static const _enter = '\r';

  /// Answers every question of [set] whose tab shows unanswered, and returns
  /// the indexes of those it left because the terminal already showed them
  /// answered (☒) — never typed over.
  Future<List<int>> answer(
    String sessionId,
    AgentQuestionSet set,
    List<AgentQuestionAnswer> answers,
  ) async {
    if (readScreen(sessionId) == null) {
      throw const SessionPromptRefusal('this session has no live terminal');
    }
    final list = set.questions;
    if (answers.length != list.length) {
      throw SessionPromptRefusal(
        '${answers.length} answers for ${list.length} questions',
      );
    }
    // Refused before a key is pressed: words typed where the question draws
    // no row for them would land on an option instead.
    for (final (i, question) in list.indexed) {
      if (answers[i].text == null) continue;
      if (!question.ownWords) {
        throw SessionPromptRefusal(
          '"${question.question}" has no row for own words',
        );
      }
      if (question.multiSelect) {
        throw const SessionPromptRefusal(
          'own words on a multi-choice question',
        );
      }
    }
    final review = list.length > 1 || list.any((q) => q.multiSelect);
    final first = await _until(
      sessionId,
      set,
      (screen) => screen.shown != null,
      'any of its questions on screen',
    );
    final answered = first.answered ?? List.filled(list.length, false);
    if (answered.length != list.length) {
      throw SessionPromptRefusal(
        'the terminal shows ${answered.length} question tabs for '
        '${list.length} questions, so nothing was answered',
      );
    }
    if (first.answered == null && first.shown != 0) {
      throw const SessionPromptRefusal(
        'the terminal shows a later question and no tabs saying which are '
        'answered, so nothing was answered',
      );
    }
    final pending = [
      for (var i = 0; i < list.length; i++)
        if (!answered[i]) i,
    ];
    if (pending.isEmpty) {
      throw const SessionPromptRefusal(
        'every question already shows answered in the terminal, so nothing '
        'was typed — submit it there',
      );
    }

    for (final i in pending) {
      final question = list[i];
      final answer = answers[i];
      final n = question.options.length;
      await _goTo(sessionId, set, i);
      await Future<void>.delayed(settle);
      await _wake(sessionId);

      final text = answer.text;
      if (text != null) {
        await _moveTo(sessionId, n + 1, 'Type something');
        _press(sessionId, text);
        await _untilRows(
          sessionId,
          (rows) => _typed(rows, n + 1, text),
          'the words typed',
        );
      } else if (!question.multiSelect) {
        final chosen = answer.chosen;
        if (chosen.length != 1 || chosen.single < 0 || chosen.single >= n) {
          throw SessionPromptRefusal('no such option: $chosen');
        }
        await _moveTo(
          sessionId,
          chosen.single + 1,
          question.options[chosen.single].label,
        );
      } else {
        final chosen = answer.chosen.toSet().toList()..sort();
        if (chosen.isEmpty || chosen.any((c) => c < 0 || c >= n)) {
          throw SessionPromptRefusal('no such option: $chosen');
        }
        for (final index in chosen) {
          final label = question.options[index].label;
          await _moveTo(sessionId, index + 1, label);
          _press(sessionId, _enter);
          await _untilRows(
            sessionId,
            (rows) => _ticked(_marked(rows)),
            '"$label" ticked',
          );
        }
        await _moveTo(sessionId, n + 2, 'Next / Submit');
      }
      // Enter moves on: to the next tab, the review, or — for one
      // single-choice question — back to the conversation.
      _press(sessionId, _enter);
      if (!review) return _leftAnswered(answered);
      final moved = await _until(
        sessionId,
        set,
        (screen) => screen.review || (screen.shown ?? i) != i,
        'the screen after question ${i + 1}',
      );
      if (moved.answered case final ticks? when !ticks[i]) {
        throw SessionPromptRefusal(
          'question ${i + 1} does not show answered in the terminal, so the '
          'answer stopped there — check the terminal',
        );
      }
    }

    await _goTo(sessionId, set, list.length);
    if (_flat(
      readScreen(sessionId) ?? const [],
    ).contains('You have not answered all questions')) {
      throw const SessionPromptRefusal(
        'the review says not every question is answered, so it was not '
        'submitted — check the terminal',
      );
    }
    await Future<void>.delayed(settle);
    await _wake(sessionId);
    _press(sessionId, _enter);
    return _leftAnswered(answered);
  }

  static List<int> _leftAnswered(List<bool> answered) => [
    for (var i = 0; i < answered.length; i++)
      if (answered[i]) i,
  ];

  /// Leaves the question to talk it over: the highlight to the row reading
  /// [rowWords] ("Chat about this"), each step seen, then Enter. That row has
  /// no number of its own the answer rows could be counted to.
  Future<void> chatAbout(
    String sessionId,
    AgentQuestionSet set,
    String rowWords,
  ) async {
    if (readScreen(sessionId) == null) {
      throw const SessionPromptRefusal('this session has no live terminal');
    }
    await _until(
      sessionId,
      set,
      (screen) => screen.shown != null,
      'any of its questions on screen',
    );
    await Future<void>.delayed(settle);
    final deadline = DateTime.now().add(screenPatience);
    var marked = _marked(readScreen(sessionId) ?? const []);
    while (!(marked?.contains(rowWords) ?? false)) {
      if (DateTime.now().isAfter(deadline)) {
        throw SessionPromptRefusal(
          'the highlight did not reach "$rowWords", so nothing was chosen '
          '— check the terminal',
        );
      }
      final before = marked;
      if (before == null) {
        await Future<void>.delayed(poll);
        marked = _marked(readScreen(sessionId) ?? const []);
        continue;
      }
      _press(sessionId, _down);
      final stepDeadline = DateTime.now().add(stepPatience);
      while ((marked == before || marked == null) &&
          DateTime.now().isBefore(stepDeadline)) {
        await Future<void>.delayed(poll);
        marked = _marked(readScreen(sessionId) ?? const []);
      }
    }
    _press(sessionId, _enter);
  }

  void _press(String sessionId, String keys) {
    if (!press(sessionId, keys)) {
      throw const SessionPromptRefusal('this session has no live terminal');
    }
  }

  /// Brings up tab [target] — `set.questions.length` is the review — one tab
  /// at a time, each step seen before the next.
  Future<void> _goTo(String sessionId, AgentQuestionSet set, int target) async {
    final count = set.questions.length;
    final what = target == count
        ? 'the review of your answers'
        : 'question ${target + 1}';
    final deadline = DateTime.now().add(screenPatience);
    QuestionScreen read() =>
        readQuestionScreen(readScreen(sessionId) ?? const [], set);
    var screen = read();
    int? at() => screen.review ? count : screen.shown;
    while (at() != target) {
      if (DateTime.now().isAfter(deadline)) {
        throw SessionPromptRefusal(
          'never saw $what, so the answer stopped there — check the terminal',
        );
      }
      final from = at();
      if (from == null) {
        await Future<void>.delayed(poll);
        screen = read();
        continue;
      }
      // On the own-words row ← and → move its text cursor, not the tab.
      final question = from < count ? set.questions[from] : null;
      final rows = readScreen(sessionId) ?? const [];
      if (question != null &&
          question.ownWords &&
          _at(rows) == question.options.length + 1) {
        await _moveTo(sessionId, question.options.length, 'an option');
      }
      _press(sessionId, from < target ? _right : _left);
      final stepDeadline = DateTime.now().add(stepPatience);
      while ((at() == from || at() == null) &&
          DateTime.now().isBefore(stepDeadline)) {
        await Future<void>.delayed(poll);
        screen = read();
      }
    }
  }

  /// The highlight one row away and back, each step seen: a tab drops the
  /// first key after it is drawn, and an Enter that is dropped cannot be
  /// pressed again — it may have landed late, on the next tab.
  Future<void> _wake(String sessionId) async {
    await _untilRows(
      sessionId,
      (rows) => _at(rows) != null,
      'one highlighted row',
    );
    final at = _at(readScreen(sessionId) ?? const [])!;
    await _moveTo(sessionId, at == 1 ? 2 : at - 1, 'the next row');
    await _moveTo(sessionId, at, 'the row it was on');
  }

  /// Moves the highlight to row [target] (1-based; `Next` is n+2) one step at
  /// a time, each step seen before the next.
  Future<void> _moveTo(String sessionId, int target, String what) async {
    final deadline = DateTime.now().add(screenPatience);
    var at = _at(readScreen(sessionId) ?? const []);
    while (at != target) {
      if (DateTime.now().isAfter(deadline)) {
        throw SessionPromptRefusal(
          'the highlight did not reach "$what", so the answer stopped there '
          '— check the terminal',
        );
      }
      // A frame caught mid-redraw shows no highlight, or two: no key on it.
      final from = at;
      if (from == null) {
        await Future<void>.delayed(poll);
        at = _at(readScreen(sessionId) ?? const []);
        continue;
      }
      _press(sessionId, from < target ? _down : _up);
      final stepDeadline = DateTime.now().add(stepPatience);
      while ((at == from || at == null) &&
          DateTime.now().isBefore(stepDeadline)) {
        await Future<void>.delayed(poll);
        at = _at(readScreen(sessionId) ?? const []);
      }
    }
  }

  Future<QuestionScreen> _until(
    String sessionId,
    AgentQuestionSet set,
    bool Function(QuestionScreen screen) test,
    String what,
  ) async {
    final deadline = DateTime.now().add(screenPatience);
    while (true) {
      final screen = readQuestionScreen(readScreen(sessionId) ?? const [], set);
      if (test(screen)) return screen;
      if (DateTime.now().isAfter(deadline)) {
        throw SessionPromptRefusal(
          'never saw $what, so the answer stopped there — check the terminal',
        );
      }
      await Future<void>.delayed(poll);
    }
  }

  Future<void> _untilRows(
    String sessionId,
    bool Function(List<String> rows) test,
    String what,
  ) async {
    final deadline = DateTime.now().add(screenPatience);
    while (!test(readScreen(sessionId) ?? const [])) {
      if (DateTime.now().isAfter(deadline)) {
        throw SessionPromptRefusal(
          'never saw $what, so the answer stopped there — check the terminal',
        );
      }
      await Future<void>.delayed(poll);
    }
  }

  // `[√]` is the tick where Claude Code's figures fall back to ASCII.
  static bool _ticked(String? marked) =>
      marked != null && (marked.contains('[✔]') || marked.contains('[√]'));

  /// Whether row [number], the own-words row, holds [text], read as
  /// tolerantly as a question is.
  static bool _typed(List<String> rows, int number, String text) {
    final row = RegExp('^\\s*(?:❯\\s+)?$number\\.\\s');
    final start = rows.lastIndexWhere(row.hasMatch);
    if (start < 0) return false;
    final block = StringBuffer(rows[start]);
    for (var r = start + 1; r < rows.length; r++) {
      if (_numbered.hasMatch(rows[r]) || rows[r].trimLeft().startsWith('─')) {
        break;
      }
      block.write(' ${rows[r]}');
    }
    final want = _letters(text);
    if (want.isEmpty) return _flat([block.toString()]).contains(text.trim());
    return _share(want, _letters(block.toString().replaceFirst(row, ''))) >=
        kQuestionMatchShare;
  }

  /// The highlighted row's words, or null — for none, or two.
  static String? _marked(List<String> rows) {
    final h = _highlight(rows);
    return h == null ? null : rows[h].trimLeft().substring(2).trim();
  }

  /// Which row is highlighted: its number, or n+2 for `Next`; null when the
  /// screen shows no question row highlighted.
  static int? _at(List<String> rows) {
    final marked = _marked(rows);
    if (marked == null) return null;
    final number = RegExp(r'^(\d+)\.').firstMatch(marked);
    if (number != null) return int.parse(number[1]!);
    // 2.1.274 drew `Next`; 2.1.287 draws `Submit` in its place.
    if (marked == 'Next' || marked == 'Submit') return _nextRow(rows);
    return null;
  }

  /// `Next` sits after the options and "Type something": the highest row
  /// number on screen, plus one.
  static int _nextRow(List<String> rows) {
    var highest = 0;
    for (final row in rows) {
      final m = RegExp(r'^\s*(?:❯\s+)?(\d+)\.\s').firstMatch(row);
      if (m != null && !row.contains('Chat about this')) {
        final value = int.parse(m[1]!);
        if (value > highest) highest = value;
      }
    }
    return highest + 1;
  }

  static String _flat(List<String> rows) =>
      rows.join(' ').replaceAll(RegExp(r'\s+'), ' ');
}

/// The least share of a question's letters that must be read, in order, off
/// the screen — and of the screen's that must be the question's.
const double kQuestionMatchShare = 0.8;

final _numbered = RegExp(r'^\s*(?:❯\s+)?\d+\.\s');
final _firstOption = RegExp(r'^\s*(?:❯\s+)?1\.\s');
// `[ ]` and `[×]` where Claude Code's figures fall back to ASCII.
final _tabMark = RegExp(r'☐|☒|\[ \]|\[×\]');
final _notLetter = RegExp(r'[^\p{L}\p{N}]', unicode: true);

/// What a screen of Claude Code's `AskUserQuestion` shows: which question,
/// which tabs are ticked, or the review.
class QuestionScreen {
  const QuestionScreen({this.shown, this.answered, this.review = false});

  /// The index of the question drawn; null for none, or when more than one
  /// could be it.
  final int? shown;

  /// Per question, whether its tab is ticked (☒); null with no tab bar.
  final List<bool>? answered;

  final bool review;
}

/// Reads [rows] as a screen of [set]: the review, or the question drawn and
/// the tab bar above it.
///
/// A question is matched by its letters alone — marks, spaces and punctuation
/// dropped — because a grid can drop or double an Indic cluster's code
/// points. The words between the tab bar and option 1 must hold
/// [kQuestionMatchShare] of the question's letters in order, and be that
/// share the question's, so a longer screen of other words does not pass.
/// Two questions passing is no match, and with no highlighted row there is
/// no question at all.
QuestionScreen readQuestionScreen(List<String> rows, AgentQuestionSet set) {
  final last = rows.lastIndexWhere(_isHighlighted);
  if (last < 0) return const QuestionScreen();
  final bar = _tabBar(rows, last);
  final answered = bar < 0
      ? null
      : [
          for (final m in _tabMark.allMatches(rows[bar]))
            m[0] == '☒' || m[0] == '[×]',
        ];
  final h = _highlight(rows);
  if (h == null) return QuestionScreen(answered: answered);
  if (rows.skip(bar + 1).any((row) => row.contains('1. Submit answers'))) {
    return QuestionScreen(answered: answered, review: true);
  }
  final top = bar >= 0
      ? bar + 1
      : rows.lastIndexWhere((row) => row.trimLeft().startsWith('─'), h) + 1;
  final option = rows.indexWhere(_firstOption.hasMatch, top);
  if (option < 0 || option > h) return QuestionScreen(answered: answered);
  final words = _letters(rows.sublist(top, option).join(' '));
  int? shown;
  for (final (i, question) in set.questions.indexed) {
    final want = _letters(question.question);
    if (want.isEmpty || _share(want, words) < kQuestionMatchShare) continue;
    if (shown != null) return QuestionScreen(answered: answered);
    shown = i;
  }
  return QuestionScreen(shown: shown, answered: answered);
}

bool _isHighlighted(String row) => row.trimLeft().startsWith('❯ ');

/// The tab bar above row [below], or -1.
int _tabBar(List<String> rows, int below) => rows.lastIndexWhere(
  (row) => _tabMark.hasMatch(row) && !_numbered.hasMatch(row),
  below,
);

/// The highlighted row of the question, or null. Two under the tab bar is
/// a grid that drew a redraw one row off (Claude Code 2.1.300 on Devanagari
/// measured per cluster): which one Claude means cannot be told, so neither.
int? _highlight(List<String> rows) {
  final last = rows.lastIndexWhere(_isHighlighted);
  if (last < 0) return null;
  final bar = _tabBar(rows, last);
  if (bar >= 0 && rows.skip(bar + 1).where(_isHighlighted).length > 1) {
    return null;
  }
  return last;
}

String _letters(String text) => text.replaceAll(_notLetter, '').toLowerCase();

/// The longest common subsequence of [a] and [b] over the longer of the two:
/// 1 for the same letters, less for each one dropped, added or changed.
double _share(String a, String b) {
  final x = a.runes.toList();
  final y = b.runes.toList();
  if (x.isEmpty || y.isEmpty) return 0;
  var previous = List.filled(y.length + 1, 0);
  for (final c in x) {
    final current = List.filled(y.length + 1, 0);
    for (var j = 0; j < y.length; j++) {
      current[j + 1] = c == y[j]
          ? previous[j] + 1
          : math.max(previous[j + 1], current[j]);
    }
    previous = current;
  }
  return previous[y.length] / math.max(x.length, y.length);
}
