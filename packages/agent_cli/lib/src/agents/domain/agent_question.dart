/// A multiple-choice question an agent puts to the user — Claude Code's
/// `AskUserQuestion` — and how it is answered from outside the terminal.
///
/// Read out of the agent's **own transcript**, never off its screen: the
/// assistant record that calls the tool carries every question, option and
/// flag, and the question is open until a `tool_result` answering that call is
/// written. And answered by keys **measured** against the real CLI
/// (`packages/host/test/agents/claude_question_keys_live_test.dart`), because a
/// guessed key sequence answers a different option than the one tapped.
library;

import 'dart:convert';

/// One option, in the agent's own words.
class AgentQuestionOption {
  const AgentQuestionOption({required this.label, this.description = ''});

  final String label;
  final String description;
}

/// One question.
class AgentQuestion {
  const AgentQuestion({
    required this.question,
    required this.options,
    this.header = '',
    this.multiSelect = false,
  });

  final String question;

  /// The agent's short tab label for it ("Fruit").
  final String header;

  final List<AgentQuestionOption> options;

  /// Several options may be chosen.
  final bool multiSelect;
}

/// Everything one tool call asks, and which call it is.
class AgentQuestionSet {
  const AgentQuestionSet({required this.toolUseId, required this.questions});

  /// The tool call's id. An answer names it, so an answer meant for a question
  /// that has since closed cannot land on the next one.
  final String toolUseId;

  final List<AgentQuestion> questions;

  /// The questions in a tool call's `input`, or null for a shape this build
  /// cannot read — which is no question, never a guessed one.
  static AgentQuestionSet? fromToolInput(String toolUseId, Object? input) {
    if (input is! Map) return null;
    final raw = input['questions'];
    if (raw is! List || raw.isEmpty) return null;
    final questions = <AgentQuestion>[];
    for (final entry in raw) {
      if (entry is! Map) return null;
      final question = entry['question'];
      final options = entry['options'];
      if (question is! String || options is! List || options.isEmpty) {
        return null;
      }
      final read = <AgentQuestionOption>[];
      for (final option in options) {
        final label = option is Map ? option['label'] : option;
        if (label is! String || label.isEmpty) return null;
        final description = option is Map ? option['description'] : null;
        read.add(
          AgentQuestionOption(
            label: label,
            description: description is String ? description : '',
          ),
        );
      }
      questions.add(
        AgentQuestion(
          question: question,
          header: entry['header'] is String ? entry['header']! as String : '',
          multiSelect: entry['multiSelect'] == true,
          options: read,
        ),
      );
    }
    return AgentQuestionSet(toolUseId: toolUseId, questions: questions);
  }
}

/// What the user chose for one question: option indexes, or their own words.
class AgentQuestionAnswer {
  const AgentQuestionAnswer.option(int index)
    : selected = const [],
      text = null,
      _one = index;

  const AgentQuestionAnswer.options(this.selected) : text = null, _one = null;

  const AgentQuestionAnswer.text(String this.text)
    : selected = const [],
      _one = null;

  final List<int> selected;
  final String? text;
  final int? _one;

  /// The chosen option indexes, whichever constructor made this.
  List<int> get chosen => _one == null ? selected : [_one];

  @override
  String toString() => text != null ? 'text($text)' : 'options($chosen)';
}

/// How one agent's questions are found and answered.
class AgentQuestionSupport {
  const AgentQuestionSupport({
    required this.toolName,
    required this.keysFor,
    required this.declineKeys,
    this.hookEvent,
    this.hookToolNamePath = const ['tool_name'],
    this.hookToolInputPath = const ['tool_input'],
  });

  /// The tool whose call is a question.
  final String toolName;

  /// The hook event that fires as the question opens (PreToolUse), or null
  /// when this agent's hooks do not announce it.
  final String? hookEvent;

  /// Where that event's payload names the tool, and carries its input.
  final List<String> hookToolNamePath;
  final List<String> hookToolInputPath;

  /// The keys that give [answers] to [questions], in order. Throws
  /// [ArgumentError] for an answer that does not fit — nothing is typed then.
  final String Function(
    AgentQuestionSet questions,
    List<AgentQuestionAnswer> answers,
  )
  keysFor;

  /// The keys that dismiss the question without answering it.
  final String declineKeys;
}

/// The question [support]'s tool asked in [transcriptTail] that no later record
/// answers, or null. Walks the tail in order, so the newest call wins and a
/// half-written line is skipped.
AgentQuestionSet? openQuestionIn(
  String transcriptTail,
  AgentQuestionSupport support,
) {
  AgentQuestionSet? open;
  for (final line in transcriptTail.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    Object? record;
    try {
      record = jsonDecode(trimmed);
    } on FormatException {
      continue;
    }
    if (record is! Map) continue;
    final message = record['message'];
    final content = message is Map ? message['content'] : null;
    if (content is! List) continue;
    for (final block in content) {
      if (block is! Map) continue;
      if (block['type'] == 'tool_use' && block['name'] == support.toolName) {
        final id = block['id'];
        if (id is String) {
          open = AgentQuestionSet.fromToolInput(id, block['input']);
        }
      } else if (block['type'] == 'tool_result' &&
          open != null &&
          block['tool_use_id'] == open.toolUseId) {
        open = null;
      }
    }
  }
  return open;
}

const _down = '\x1b[B';
const _enter = '\r';

/// [keys] split the way a terminal sends them: an escape sequence whole, a run
/// of printable text whole, every other control key alone. Written to the TUI
/// one at a time, because a burst crossing a question's tabs loses keys
/// (docs/SETTLED.md).
List<String> keystrokesOf(String keys) => [
  for (final m in RegExp(
    r'\x1b\[[0-9;]*[A-Za-z~]|[\x00-\x1f\x7f]|[^\x00-\x1f\x7f]+',
  ).allMatches(keys))
    m[0]!,
];

/// Claude Code 2.1.274's `AskUserQuestion`, as measured:
///
/// - each question opens with its first option highlighted; ↓ moves;
/// - on a single-choice question, Enter chooses the highlighted option and
///   moves on by itself;
/// - the free-text row ("Type something") sits after the options, and typing
///   there then Enter answers with the text;
/// - on a multi-choice question, Enter toggles the highlighted box, and a
///   `Next` row after "Type something" moves on;
/// - more than one question, or any multi-choice one, ends on a `Submit` tab
///   that takes one more Enter. A single single-choice question does not.
String claudeQuestionKeys(
  AgentQuestionSet questions,
  List<AgentQuestionAnswer> answers,
) {
  final list = questions.questions;
  if (answers.length != list.length) {
    throw ArgumentError(
      '${answers.length} answers for ${list.length} questions',
    );
  }
  final keys = StringBuffer();
  for (var i = 0; i < list.length; i++) {
    final question = list[i];
    final answer = answers[i];
    final count = question.options.length;
    final text = answer.text;
    if (text != null) {
      if (question.multiSelect) {
        throw ArgumentError('own words on a multi-choice question');
      }
      if (text.trim().isEmpty || text.runes.any((r) => r < 0x20 || r == 0x7f)) {
        throw ArgumentError('the answer must be one line of printable text');
      }
      keys
        ..write(_down * count)
        ..write(text)
        ..write(_enter);
      continue;
    }
    final chosen = answer.chosen.toSet().toList()..sort();
    if (chosen.isEmpty || chosen.any((c) => c < 0 || c >= count)) {
      throw ArgumentError('no such option: ${answer.chosen}');
    }
    if (!question.multiSelect) {
      if (chosen.length != 1) {
        throw ArgumentError('one option on a single-choice question');
      }
      keys
        ..write(_down * chosen.single)
        ..write(_enter);
      continue;
    }
    var cursor = 0;
    for (final index in chosen) {
      keys
        ..write(_down * (index - cursor))
        ..write(_enter);
      cursor = index;
    }
    // Past "Type something" to `Next`.
    keys
      ..write(_down * (count + 1 - cursor))
      ..write(_enter);
  }
  if (list.length > 1 || list.any((q) => q.multiSelect)) keys.write(_enter);
  return keys.toString();
}
