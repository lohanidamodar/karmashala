import 'package:chitragupta/src/features/sessions/domain/handoff_packet.dart';
import 'package:flutter_test/flutter_test.dart';

HandoffPacket _packet({
  List<HandoffTurn> recap = const [],
  int omittedTurns = 0,
  List<HandoffChange>? changes = const [],
  List<String> unresolvedTasks = const [],
  String? branch = 'feature/x',
  int? commitsAhead = 2,
  String? baseBranch = 'origin/main',
  bool isFork = false,
  String instruction = 'Finish the parser.',
}) => HandoffPacket(
  sourceAgentName: 'Claude Code',
  targetAgentName: 'Codex CLI',
  sourceTitle: 'Fix the parser',
  sourceSessionId: 'a4f1',
  instruction: instruction,
  workingDirectory: '/src/demo',
  branch: branch,
  commitsAhead: commitsAhead,
  baseBranch: baseBranch,
  changes: changes,
  recap: recap,
  omittedTurns: omittedTurns,
  unresolvedTasks: unresolvedTasks,
  isFork: isFork,
);

void main() {
  group('provenance — the rule the packet exists for', () {
    test('names the source agent and denies authorship of the recap', () {
      final text = _packet().render();
      expect(text, startsWith('# Handed off from Claude Code'));
      expect(text, contains('**Claude Code** was doing'));
      // The receiving agent must not come away believing it wrote the work.
      expect(text, contains('not your own history'));
      expect(text, contains('things you are inheriting'));
    });

    test('states both ends of the handoff, and the session it came from', () {
      final text = _packet().render();
      expect(text, contains('**Previous agent:** Claude Code'));
      expect(text, contains('**You are:** Codex CLI'));
      expect(text, contains('"Fix the parser" (`a4f1`)'));
    });

    test('a fork says the original still exists and is unchanged', () {
      final text = _packet(isFork: true).render();
      expect(text, startsWith('# Forked from Claude Code'));
      expect(text, contains('branch'));
      expect(text, contains('The original session still exists'));
      expect(text, contains('you are continuing *from* it'));
    });
  });

  group('what could not be established says so', () {
    test('null changes admits git was not answered, empty says clean', () {
      expect(
        _packet(changes: null).render(),
        contains('Could not be read — git did not answer'),
      );
      expect(
        _packet(changes: const []).render(),
        contains('None: the working tree is clean'),
      );
    });

    test('an unknown branch is stated, not omitted', () {
      final text = _packet(branch: null).render();
      expect(text, contains('**Branch:** unknown (git could not be asked)'));
    });

    test('an unmeasured ahead-count drops to the branch alone', () {
      expect(
        _packet(commitsAhead: null).render(),
        contains('**Branch:** `feature/x`'),
      );
      expect(_packet(commitsAhead: null).render(), isNot(contains('ahead of')));
    });

    test('the ahead-count is pluralised honestly', () {
      expect(
        _packet(commitsAhead: 1).render(),
        contains('1 commit ahead of `origin/main`'),
      );
      expect(
        _packet(commitsAhead: 2).render(),
        contains('2 commits ahead of `origin/main`'),
      );
    });
  });

  group('the recap is quoted, attributed and measured', () {
    const turns = [
      HandoffTurn(speaker: 'User', text: 'Parse the header.'),
      HandoffTurn(speaker: 'Claude Code', text: 'Done, in lib/a.dart.'),
    ];

    test('every quoted line is a blockquote under a named speaker', () {
      final text = _packet(recap: turns).render();
      expect(text, contains('**Claude Code:**'));
      expect(text, contains('> Done, in lib/a.dart.'));
      // Never "assistant": the reader is itself an assistant, and the whole
      // point is that it does not mistake these turns for its own.
      expect(text, isNot(contains('**assistant:**')));
    });

    test('a multi-line turn is quoted line by line', () {
      final text = _packet(
        recap: const [HandoffTurn(speaker: 'User', text: 'one\ntwo')],
      ).render();
      expect(text, contains('> one'));
      expect(text, contains('> two'));
    });

    test('says how much was left out, and that it was a tail', () {
      final text = _packet(recap: turns, omittedTurns: 40).render();
      expect(text, contains('The last 2 of 42 turns'));
      expect(text, contains('ask rather than assume'));
    });

    test('a complete recap says so instead of implying a cut', () {
      expect(
        _packet(recap: turns).render(),
        contains('All 2 turns, oldest first, quoted verbatim.'),
      );
    });

    test(
      'an empty transcript is stated, and distinguished from a lost one',
      () {
        expect(
          _packet().render(),
          contains('Nothing was said in that session yet'),
        );
        expect(
          _packet(omittedTurns: 12).render(),
          contains('could not be quoted here, though it has 12 earlier turns'),
        );
      },
    );
  });

  group('the instruction and open work', () {
    test('the instruction is last, under its own heading', () {
      final text = _packet(instruction: 'Take over the merge.').render();
      expect(text, endsWith('Take over the merge.'));
      expect(text, contains('## What you are being asked to do'));
    });

    test('unresolved tasks are passed through unedited, as open boxes', () {
      final text = _packet(
        unresolvedTasks: const ['tests for the lexer', 'the CHANGELOG'],
      ).render();
      expect(text, contains('- [ ] tests for the lexer'));
      expect(text, contains('- [ ] the CHANGELOG'));
    });

    test('the section disappears when the user marked nothing', () {
      expect(_packet().render(), isNot(contains('Still open')));
    });
  });

  group('changed files', () {
    test('lists each file with what happened to it', () {
      final text = _packet(
        changes: const [
          HandoffChange(path: 'lib/a.dart', state: 'modified'),
          HandoffChange(
            path: 'lib/c.dart',
            state: 'renamed',
            originalPath: 'lib/b.dart',
          ),
        ],
      ).render();
      expect(text, contains('- `lib/a.dart` — modified'));
      expect(text, contains('- `lib/c.dart` — renamed from `lib/b.dart`'));
    });
  });

  group('trimRecap', () {
    List<HandoffTurn> turns(int count, {int size = 10}) => [
      for (var i = 0; i < count; i++)
        HandoffTurn(speaker: 'User', text: '$i'.padRight(size, '.')),
    ];

    test('keeps the most recent turns, oldest first, and counts the rest', () {
      final result = trimRecap(
        turns(10),
        const HandoffRecapBudget(maxTurns: 3),
      );
      expect(result.turns, hasLength(3));
      expect(result.omitted, 7);
      // Recency wins because the end of a conversation holds the current
      // state; the beginning holds the original request, which the user is
      // about to restate as the instruction.
      expect(result.turns.first.text, startsWith('7'));
      expect(result.turns.last.text, startsWith('9'));
    });

    test('stops at the character budget as well as the turn count', () {
      final result = trimRecap(
        turns(10, size: 100),
        const HandoffRecapBudget(maxCharacters: 250, maxTurns: 50),
      );
      expect(result.turns.length, lessThan(10));
      expect(result.omitted, 10 - result.turns.length);
    });

    test('always keeps the final turn, however enormous', () {
      // A packet whose recap is empty because one message was huge is strictly
      // worse than one that is over budget by a single message.
      final result = trimRecap([
        HandoffTurn(speaker: 'User', text: 'x' * 50000),
      ], const HandoffRecapBudget(maxCharacters: 10, maxCharactersPerTurn: 40));
      expect(result.turns, hasLength(1));
      expect(result.omitted, 0);
    });

    test('truncates an over-long turn in the middle, keeping both ends', () {
      final result = trimRecap([
        HandoffTurn(speaker: 'User', text: 'HEAD${'.' * 400}TAIL'),
      ], const HandoffRecapBudget(maxCharactersPerTurn: 120));
      final text = result.turns.single.text;
      // A tool result or a pasted log has its outcome at the bottom, so
      // tail-only truncation reliably keeps the least useful half.
      expect(text, startsWith('HEAD'));
      expect(text, endsWith('TAIL'));
      expect(text, contains('trimmed for the handoff'));
      expect(text.length, lessThan(200));
    });

    test('leaves a conversation that already fits completely alone', () {
      final input = turns(4);
      final result = trimRecap(input);
      expect(result.turns, input);
      expect(result.omitted, 0);
    });
  });
}
