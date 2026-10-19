import 'package:agent_cli/descriptors.dart';
import 'package:test/test.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';

/// Claude Code's AskUserQuestion as drawn by 2.1.274 (captured with the live
/// probe), and the failure seen on the Oppo: the first key after a tab change
/// is dropped.
class FakeQuestionScreen {
  FakeQuestionScreen(
    this.set, {
    this.dropAfterTab = true,
    this.continueWord = 'Next',
    this.tabBar = true,
    this.drawQuestion,
    Map<int, String> answeredBefore = const {},
    this.tab = 0,
  }) {
    chosen.addAll(answeredBefore);
  }

  final AgentQuestionSet set;
  final bool dropAfterTab;

  /// The row after a multi-choice question's options: `Next` on 2.1.274,
  /// `Submit` on 2.1.287 (read off the probe, 2026-10-04).
  final String continueWord;

  /// Draws `←  ☐ A  ☒ B  ✔ Submit  →` above the question, as 2.1.287 does.
  final bool tabBar;

  /// How the grid shows a question's words; the words themselves by default.
  final String Function(String question)? drawQuestion;

  int tab;
  int row = 1; // 1-based; n+1 Type something, n+2 Next.
  final Map<int, Set<int>> ticked = {};
  final Map<int, String> typed = {};
  final Map<int, String> chosen = {};
  bool review = false;
  bool done = false;
  bool chatting = false;
  bool _dropNext = false;
  final List<String> keys = [];

  /// Keys that landed somewhere the typist must never send them.
  final List<String> misplaced = [];

  AgentQuestion get _q => set.questions[tab];

  bool get _multi =>
      set.questions.length > 1 || set.questions.any((x) => x.multiSelect);

  String get _bar {
    final tabs = [
      for (final (i, q) in set.questions.indexed)
        '${chosen.containsKey(i) ? '☒' : '☐'} ${q.header.isEmpty ? 'Q${i + 1}' : q.header}',
    ];
    if (!_multi) return ' ${tabs.single}';
    return '←  ${tabs.join('  ')}  ✔ Submit  →';
  }

  List<String> get rows {
    if (done) return const ['❯ '];
    if (review) {
      return [
        if (tabBar) _bar,
        'Review your answers',
        if (chosen.length < set.questions.length)
          '⚠ You have not answered all questions',
        'Ready to submit your answers?',
        '${row == 1 ? '❯' : ' '} 1. Submit answers',
        '${row == 2 ? '❯' : ' '} 2. Cancel',
      ];
    }
    final q = _q;
    final n = q.options.length;
    String mark(int r) => r == row ? '❯ ' : '  ';
    return [
      if (tabBar) _bar,
      '',
      drawQuestion?.call(q.question) ?? q.question,
      '',
      for (var i = 0; i < n; i++) ...[
        q.multiSelect
            ? '${mark(i + 1)}${i + 1}. [${ticked[tab]?.contains(i) ?? false ? '✔' : ' '}] ${q.options[i].label}'
            : '${mark(i + 1)}${i + 1}. ${q.options[i].label}',
        '     ${q.options[i].label}',
      ],
      '${mark(n + 1)}${n + 1}. ${typed[tab] ?? 'Type something.'}',
      if (q.multiSelect) '${row == n + 2 ? '❯' : ' '}    $continueWord',
      '${mark(n + 2 + (q.multiSelect ? 1 : 0))}${n + 2 + (q.multiSelect ? 1 : 0)}. Chat about this',
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
      if (k == '\r' && row == 1) done = true;
      if (k == '\r' && row == 2) misplaced.add('Cancel');
      if (k == '\x1b[B' && row == 1) row = 2;
      if (k == '\x1b[A' && row == 2) row = 1;
      if (k == '\x1b[D') {
        review = false;
        tab = set.questions.length - 1;
        row = 1;
      }
      return true;
    }
    final q = _q;
    final n = q.options.length;
    final last = q.multiSelect ? n + 3 : n + 2;
    final chatRow = q.multiSelect ? n + 3 : n + 2;
    switch (k) {
      // In the own-words row ← and → move its text cursor.
      case '\x1b[C' || '\x1b[D' when row == n + 1:
        misplaced.add(k);
      case '\x1b[C':
        if (tab + 1 < set.questions.length) {
          tab++;
          row = 1;
        } else if (_multi) {
          review = true;
          row = 1;
        }
      case '\x1b[D':
        if (tab > 0) {
          tab--;
          row = 1;
        }
      case '\r' when chosen.containsKey(tab):
        misplaced.add('Enter on answered question ${tab + 1}');
      case '\x1b[B':
        if (row < last) row++;
      case '\x1b[A':
        if (row > 1) row--;
      case '\r' when row == chatRow:
        chatting = true;
        done = true;
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
        if (tab + 1 < set.questions.length) {
          tab++;
          row = 1;
          _dropNext = dropAfterTab;
        } else if (_multi) {
          review = true;
          row = 1;
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
    ownWords: true,
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

  test('own words for a question drawn without an Other row are refused '
      'before a key is pressed', () async {
    const designs = AgentQuestion(
      question: 'Which layout?',
      options: [
        AgentQuestionOption(label: 'Grid', preview: '+--+'),
        AgentQuestionOption(label: 'List', preview: '----'),
      ],
    );
    const set = AgentQuestionSet(toolUseId: 't', questions: [fruit, designs]);
    final screen = FakeQuestionScreen(set);

    await expectLater(
      typistOn(screen).answer('s', set, const [
        AgentQuestionAnswer.option(0),
        AgentQuestionAnswer.text('Tabs'),
      ]),
      throwsA(
        isA<SessionPromptRefusal>().having(
          (r) => r.message,
          'message',
          contains('no row for own words'),
        ),
      ),
    );
    expect(screen.keys, isEmpty);
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

  test(
    '2.1.287 names the row after the options "Submit", not "Next"',
    () async {
      const toppings = AgentQuestion(
        question: 'Pick toppings',
        multiSelect: true,
        options: [
          AgentQuestionOption(label: 'Nuts'),
          AgentQuestionOption(label: 'Honey'),
          AgentQuestionOption(label: 'Yogurt'),
        ],
      );
      const set = AgentQuestionSet(toolUseId: 't', questions: [toppings]);
      final screen = FakeQuestionScreen(set, continueWord: 'Submit');

      await typistOn(screen).answer('s', set, const [
        AgentQuestionAnswer.options([0, 2]),
      ]);

      expect(screen.chosen, {0: 'Nuts, Yogurt'});
      expect(screen.done, isTrue);
    },
  );

  group('Devanagari, and tabs already answered', () {
    AgentQuestion nepali(String header, String question) => AgentQuestion(
      header: header,
      question: question,
      ownWords: true,
      options: const [
        AgentQuestionOption(label: 'राख्ने'),
        AgentQuestionOption(label: 'हटाउने'),
      ],
    );
    final puja = AgentQuestionSet(
      toolUseId: 't',
      questions: [
        nepali('नवमी होम', 'नवमीको होम बुकमा छ। राख्ने?'),
        nepali('पाठ', 'सप्तशती पाठ समाप्ति चरण बुकको नवमीमा छैन। राख्ने?'),
        nepali('बलि', 'बलि चढाउने विधि दशमीमा सार्ने?'),
        nepali('खड्ग', 'खड्ग पूजा अष्टमीमै गर्ने?'),
      ],
    );
    // The Karmakanda session's pane as the server's grid held it,
    // 2026-10-19: "पाठ स" read "पस", and "बुकको न" read "बन".
    const karmakanda = [
      '←  ☒ नवमी होम  ☐ पाठ  ☐ बलि  ☐ खड्ग  ✔ Submit  →',
      '',
      'सप्तशती पसमाप्ति चरण बनवमीमा छैन। राख्ने?',
      '',
      '❯ 1. राख्ने',
      '  2. हटाउने',
      '  3. Type something.',
      '────────────────────────────',
      '  4. Chat about this',
      '',
      'Enter to select · Tab/Arrow keys to navigate · Esc to cancel',
    ];

    test('the mangled screen reads as question 2, with tab 1 ticked', () {
      final screen = readQuestionScreen(karmakanda, puja);

      expect(screen.shown, 1);
      expect(screen.answered, [true, false, false, false]);
      expect(screen.review, isFalse);
    });

    test('a question that is not the one drawn does not match it', () {
      final other = AgentQuestionSet(
        toolUseId: 't',
        questions: [
          nepali('पाठ', 'चण्डी पाठ अष्टमीमा पूरा गर्ने?'),
          nepali('समय', 'सप्तशती पाठ कति बजे सुरु गर्ने?'),
        ],
      );

      expect(readQuestionScreen(karmakanda, other).shown, isNull);
    });

    test('a screen with no highlight is no question', () {
      final rows = [
        for (final row in karmakanda) row.replaceFirst('❯ 1.', '  1.'),
      ];

      expect(readQuestionScreen(rows, puja).shown, isNull);
    });

    test('a question the screen cannot be told apart from another is no '
        'match', () {
      final twins = AgentQuestionSet(
        toolUseId: 't',
        questions: [puja.questions[1], puja.questions[1]],
      );

      expect(readQuestionScreen(karmakanda, twins).shown, isNull);
    });

    // Drops a mark and doubles a letter in every question, as the grid did.
    String mangle(String q) =>
        q.replaceFirst('ा', '').replaceFirst('न', 'नन').replaceFirst('ु', '');

    test(
      'answers from tab 2 on, leaving tab 1 as the terminal has it',
      () async {
        final screen = FakeQuestionScreen(
          puja,
          drawQuestion: mangle,
          answeredBefore: {0: 'राख्ने'},
          tab: 1,
        );

        final left = await typistOn(screen).answer('s', puja, const [
          AgentQuestionAnswer.option(1),
          AgentQuestionAnswer.option(0),
          AgentQuestionAnswer.option(1),
          AgentQuestionAnswer.text('भोलि'),
        ]);

        expect(left, [0]);
        expect(screen.chosen, {
          0: 'राख्ने',
          1: 'राख्ने',
          2: 'हटाउने',
          3: 'भोलि',
        });
        expect(screen.done, isTrue);
        expect(screen.misplaced, isEmpty);
      },
    );

    test('goes back to the first unanswered tab, and over answered ones, one '
        'step at a time', () async {
      final screen = FakeQuestionScreen(
        puja,
        answeredBefore: {1: 'राख्ने'},
        tab: 3,
      );

      final left = await typistOn(screen).answer('s', puja, const [
        AgentQuestionAnswer.option(0),
        AgentQuestionAnswer.option(0),
        AgentQuestionAnswer.option(1),
        AgentQuestionAnswer.option(0),
      ]);

      expect(left, [1]);
      expect(screen.chosen, {
        0: 'राख्ने',
        1: 'राख्ने',
        2: 'हटाउने',
        3: 'राख्ने',
      });
      expect(screen.done, isTrue);
      expect(screen.misplaced, isEmpty);
    });

    test(
      'a question of another set on screen is refused before a key',
      () async {
        final screen = FakeQuestionScreen(
          AgentQuestionSet(
            toolUseId: 'other',
            questions: [nepali('समय', 'चण्डी पाठ अष्टमीमा पूरा गर्ने?')],
          ),
        );

        await expectLater(
          typistOn(screen).answer('s', puja, const [
            AgentQuestionAnswer.option(0),
            AgentQuestionAnswer.option(0),
            AgentQuestionAnswer.option(0),
            AgentQuestionAnswer.option(0),
          ]),
          throwsA(isA<SessionPromptRefusal>()),
        );
        expect(screen.keys, isEmpty);
      },
    );

    test('every tab answered already: refused, nothing typed', () async {
      final screen = FakeQuestionScreen(
        puja,
        answeredBefore: {0: 'a', 1: 'b', 2: 'c', 3: 'd'},
        tab: 3,
      );

      await expectLater(
        typistOn(screen).answer('s', puja, const [
          AgentQuestionAnswer.option(0),
          AgentQuestionAnswer.option(0),
          AgentQuestionAnswer.option(0),
          AgentQuestionAnswer.option(0),
        ]),
        throwsA(
          isA<SessionPromptRefusal>().having(
            (r) => r.message,
            'message',
            contains('already shows answered'),
          ),
        ),
      );
      expect(screen.keys, isEmpty);
    });

    test('with no tab bar, a later question on screen is refused', () async {
      final screen = FakeQuestionScreen(puja, tabBar: false, tab: 1);

      await expectLater(
        typistOn(screen).answer('s', puja, const [
          AgentQuestionAnswer.option(0),
          AgentQuestionAnswer.option(0),
          AgentQuestionAnswer.option(0),
          AgentQuestionAnswer.option(0),
        ]),
        throwsA(isA<SessionPromptRefusal>()),
      );
      expect(screen.keys, isEmpty);
    });
  });

  for (final question in [fruit, colours]) {
    test(
      '"Chat about this" leaves ${question.multiSelect ? 'a multi' : 'a '
                'single'}-choice question to talk it over',
      () async {
        final set = AgentQuestionSet(toolUseId: 't', questions: [question]);
        final screen = FakeQuestionScreen(set, continueWord: 'Submit');

        await typistOn(screen).chatAbout('s', set, 'Chat about this');

        expect(screen.chatting, isTrue);
        expect(screen.chosen, isEmpty);
      },
    );
  }
}
