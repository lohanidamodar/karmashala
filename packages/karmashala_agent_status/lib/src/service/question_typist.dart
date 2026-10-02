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
  static const _enter = '\r';

  Future<void> answer(
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
    final review = list.length > 1 || list.any((q) => q.multiSelect);
    for (var i = 0; i < list.length; i++) {
      final question = list[i];
      final answer = answers[i];
      final n = question.options.length;
      await _until(
        sessionId,
        (rows) => _shows(rows, question.question) && _at(rows) == 1,
        'the question "${question.question}"',
      );
      await Future<void>.delayed(settle);

      final text = answer.text;
      if (text != null) {
        if (question.multiSelect) {
          throw const SessionPromptRefusal(
            'own words on a multi-choice question',
          );
        }
        await _moveTo(sessionId, n + 1, 'Type something');
        _press(sessionId, text);
        await _until(
          sessionId,
          (rows) => _shows(rows, text),
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
          await _until(
            sessionId,
            (rows) => _marked(rows)?.contains('[✔]') ?? false,
            '"$label" ticked',
          );
        }
        await _moveTo(sessionId, n + 2, 'Next');
      }
      // Enter moves on: to the next tab, the review, or — for one
      // single-choice question — back to the conversation.
      _press(sessionId, _enter);
      final last = i == list.length - 1;
      if (last && review) {
        await _until(
          sessionId,
          (rows) => _marked(rows)?.contains('Submit answers') ?? false,
          'the review of your answers',
        );
        await Future<void>.delayed(settle);
        _press(sessionId, _enter);
      }
    }
  }

  void _press(String sessionId, String keys) {
    if (!press(sessionId, keys)) {
      throw const SessionPromptRefusal('this session has no live terminal');
    }
  }

  /// Moves the highlight to row [target] (1-based; `Next` is n+2) one step at
  /// a time, each step seen before the next.
  Future<void> _moveTo(String sessionId, int target, String what) async {
    final deadline = DateTime.now().add(screenPatience);
    var at = _at(readScreen(sessionId) ?? const []);
    while (at != target) {
      if (at == null || DateTime.now().isAfter(deadline)) {
        throw SessionPromptRefusal(
          'the highlight did not reach "$what", so the answer stopped there '
          '— check the terminal',
        );
      }
      _press(sessionId, at < target ? _down : _up);
      final before = at;
      final stepDeadline = DateTime.now().add(stepPatience);
      while (at == before && DateTime.now().isBefore(stepDeadline)) {
        await Future<void>.delayed(poll);
        at = _at(readScreen(sessionId) ?? const []);
      }
    }
  }

  Future<void> _until(
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

  /// The highlighted row's words, or null.
  static String? _marked(List<String> rows) {
    for (final row in rows.reversed) {
      final trimmed = row.trimLeft();
      if (trimmed.startsWith('❯ ')) return trimmed.substring(2).trim();
    }
    return null;
  }

  /// Which row is highlighted: its number, or n+2 for `Next`; null when the
  /// screen shows no question row highlighted.
  static int? _at(List<String> rows) {
    final marked = _marked(rows);
    if (marked == null) return null;
    final number = RegExp(r'^(\d+)\.').firstMatch(marked);
    if (number != null) return int.parse(number[1]!);
    if (marked == 'Next') return _nextRow(rows);
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

  static bool _shows(List<String> rows, String text) {
    final flat = rows.join(' ').replaceAll(RegExp(r'\s+'), ' ');
    final want = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    final probe = want.length > 40 ? want.substring(0, 40) : want;
    return flat.contains(probe);
  }
}
