import 'package:agent_cli/descriptors.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/application/session_menu_answerer.dart';
import 'package:karmashala/src/features/sessions/application/session_question_typist.dart';

/// Claude Code's AskUserQuestion as drawn by 2.1.274 (captured with the live
/// probe), and the failure seen on the Oppo: the first key after a tab change
/// is dropped.
class FakeQuestionScreen {
  FakeQuestionScreen(this.set, {this.dropAfterTab = true});

  final AgentQuestionSet set;
  final bool dropAfterTab;

  int tab = 0;
  int row = 1; // 1-based; n+1 Type something, n+2 Next.
  final Map<int, Set<int>> ticked = {};
  final Map<int, String> typed = {};
  final Map<int, String> chosen = {};
  bool review = false;
  bool done = false;
  bool _dropNext = false;
  final List<String> keys = [];

  AgentQuestion get _q => set.questions[tab];

  List<String> get rows {
    if (done) return const ['❯ '];
    if (review) {
      return const [
        'Review your answers',
        'Ready to submit your answers?',
        '❯ 1. Submit answers',
        '  2. Cancel',
      ];
    }
    final q = _q;
    final n = q.options.length;
    String mark(int r) => r == row ? '❯ ' : '  ';
    return [
      q.question,
      for (var i = 0; i < n; i++) ...[
        q.multiSelect
            ? '${mark(i + 1)}${i + 1}. [${ticked[tab]?.contains(i) ?? false ? '✔' : ' '}] ${q.options[i].label}'
            : '${mark(i + 1)}${i + 1}. ${q.options[i].label}',
        '     ${q.options[i].label}',
      ],
      '${mark(n + 1)}${n + 1}. ${typed[tab] ?? 'Type something.'}',
      if (q.multiSelect) '${row == n + 2 ? '❯' : ' '}    Next',
      '  ${n + 2 + (q.multiSelect ? 1 : 0)}. Chat about this',
      'Enter to select · Esc to cancel',
    ];
  }

  bool press(String k) {
    keys.add(k);
    if (_dropNext) {
      _dropNext = false;
      return true;
    }
    if (review) {
      if (k == '\r') done = true;
      return true;
    }
    final q = _q;
    final n = q.options.length;
    final last = q.multiSelect ? n + 2 : n + 1;
    switch (k) {
      case '\x1b[B':
        if (row < last) row++;
      case '\x1b[A':
        if (row > 1) row--;
      case '\r':
        if (q.multiSelect && row <= n) {
          final set = ticked.putIfAbsent(tab, () => {});
          if (!set.remove(row - 1)) set.add(row - 1);
          return true;
        }
        chosen[tab] = row == n + 1
            ? typed[tab] ?? ''
            : q.multiSelect
            ? (ticked[tab]!.toList()..sort())
                  .map((i) => q.options[i].label)
                  .join(', ')
            : q.options[row - 1].label;
        final multi =
            set.questions.length > 1 || set.questions.any((x) => x.multiSelect);
        if (tab + 1 < set.questions.length) {
          tab++;
          row = 1;
          _dropNext = dropAfterTab;
        } else if (multi) {
          review = true;
        } else {
          done = true;
        }
      default:
        if (row == n + 1) typed[tab] = (typed[tab] ?? '') + k;
    }
    return true;
  }
}

void main() {
  const colours = AgentQuestion(
    question: 'Pick colours?',
    multiSelect: true,
    options: [
      AgentQuestionOption(label: 'Red'),
      AgentQuestionOption(label: 'Green'),
      AgentQuestionOption(label: 'Blue'),
    ],
  );
  const fruit = AgentQuestion(
    question: 'Pick a fruit?',
    options: [
      AgentQuestionOption(label: 'Apple'),
      AgentQuestionOption(label: 'Banana'),
      AgentQuestionOption(label: 'Cherry'),
    ],
  );

  SessionQuestionTypist typistOn(FakeQuestionScreen screen) =>
      SessionQuestionTypist(
        readScreen: (_) => screen.rows,
        press: (_, k) => screen.press(k),
        poll: const Duration(milliseconds: 1),
        stepPatience: const Duration(milliseconds: 20),
        screenPatience: const Duration(milliseconds: 500),
        settle: Duration.zero,
      );

  test(
    'boxes then own words, though the first key after the tab is lost',
    () async {
      const set = AgentQuestionSet(toolUseId: 't', questions: [colours, fruit]);
      final screen = FakeQuestionScreen(set);

      await typistOn(screen).answer('s', set, const [
        AgentQuestionAnswer.options([0, 2]),
        AgentQuestionAnswer.text('Durian'),
      ]);

      expect(screen.chosen, {0: 'Red, Blue', 1: 'Durian'});
      expect(screen.done, isTrue);
    },
  );

  test('one option on each tab', () async {
    const set = AgentQuestionSet(toolUseId: 't', questions: [colours, fruit]);
    final screen = FakeQuestionScreen(set);

    await typistOn(screen).answer('s', set, const [
      AgentQuestionAnswer.options([1]),
      AgentQuestionAnswer.option(2),
    ]);

    expect(screen.chosen, {0: 'Green', 1: 'Cherry'});
    expect(screen.done, isTrue);
  });

  test('one single-choice question ends on its own Enter', () async {
    const set = AgentQuestionSet(toolUseId: 't', questions: [fruit]);
    final screen = FakeQuestionScreen(set);

    await typistOn(
      screen,
    ).answer('s', set, const [AgentQuestionAnswer.option(1)]);

    expect(screen.chosen, {0: 'Banana'});
    expect(screen.done, isTrue);
  });

  test('a question that never draws stops the answer, and nothing is '
      'confirmed', () async {
    const set = AgentQuestionSet(toolUseId: 't', questions: [fruit]);
    final screen = FakeQuestionScreen(set)..done = true;

    await expectLater(
      typistOn(screen).answer('s', set, const [AgentQuestionAnswer.option(1)]),
      throwsA(isA<SessionPromptRefusal>()),
    );
    expect(screen.keys, isEmpty);
  });

  test('no pane: refused at once', () async {
    const set = AgentQuestionSet(toolUseId: 't', questions: [fruit]);
    final typist = SessionQuestionTypist(
      readScreen: (_) => null,
      press: (_, _) => false,
    );

    await expectLater(
      typist.answer('s', set, const [AgentQuestionAnswer.option(1)]),
      throwsA(
        isA<SessionPromptRefusal>().having(
          (r) => r.message,
          'message',
          contains('no live terminal'),
        ),
      ),
    );
  });
}
