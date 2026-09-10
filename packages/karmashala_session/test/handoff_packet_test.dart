import 'package:karmashala_session/lineage.dart';
import 'package:test/test.dart';

HandoffPacket _packet({
  List<HandoffTurn> recap = const [],
  int omittedTurns = 0,
  List<HandoffChange>? changes = const [],
  List<String> unresolvedTasks = const [],
  List<HandoffClaim>? deadEnds = const [],
  HandoffSourceBrief? sourceBrief,
  List<HandoffDecision>? decisions = const [],
  int omittedDecisions = 0,
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
  decisions: decisions,
  omittedDecisions: omittedDecisions,
  unresolvedTasks: unresolvedTasks,
  deadEnds: deadEnds,
  sourceBrief: sourceBrief,
  isFork: isFork,
);

HandoffDecision _decision({
  String kind = 'Approach rejected',
  String summary = 'The isolate pool deadlocked on Windows.',
  String? detail,
  String? decidedBy = 'Claude Code',
  String? origin = 'verification run',
  String? originId = 'v-1',
  DateTime? recordedAt,
}) => HandoffDecision(
  kind: kind,
  summary: summary,
  detail: detail,
  decidedBy: decidedBy,
  origin: origin,
  originId: originId,
  recordedAt: recordedAt ?? DateTime.utc(2026, 8, 31, 12, 5),
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

  group('the decision record', () {
    test('is rendered ahead of the quoted recap, so it is never the part '
        'that gets cut', () {
      final text = _packet(
        decisions: [_decision()],
        recap: const [HandoffTurn(speaker: 'User', text: 'Parse the header.')],
      ).render();
      expect(
        text.indexOf('## Decisions on record'),
        lessThan(text.indexOf('## Conversation so far')),
      );
    });

    test('quotes each decision under its kind, attributed and dated', () {
      final text = _packet(decisions: [_decision()]).render();
      expect(text, contains('**Approach rejected**'));
      // Attributed, like every other line the packet prints: the reader has to
      // be able to tell a rule the user imposed from one an agent chose.
      expect(text, contains('decided by Claude Code'));
      expect(text, contains('2026-08-31 12:05Z'));
      // Quoted, never paraphrased.
      expect(text, contains('> The isolate pool deadlocked on Windows.'));
    });

    test('names the act that produced it, and its record when there is one', () {
      expect(
        _packet(decisions: [_decision()]).render(),
        contains('from verification run `v-1`'),
      );
      // An approval prompt is drawn by another program and gone once answered;
      // naming a record to open would be inventing one.
      expect(
        _packet(
          decisions: [
            _decision(origin: "the agent's own approval prompt", originId: null),
          ],
        ).render(),
        contains("from the agent's own approval prompt"),
      );
    });

    test('a decision whose origin has been pruned still renders', () {
      // Nothing dereferences an origin, so a run that has been cleaned up is
      // indistinguishable from one that has not — by design.
      final text = _packet(
        decisions: [_decision(originId: 'v-long-gone')],
      ).render();
      expect(text, contains('from verification run `v-long-gone`'));
      expect(text, contains('> The isolate pool deadlocked on Windows.'));
    });

    test('a multi-line detail is quoted line by line, like a turn', () {
      final text = _packet(
        decisions: [_decision(detail: 'one\ntwo')],
      ).render();
      expect(text, contains('> one'));
      expect(text, contains('> two'));
    });

    test('an unknown decider says "not recorded" rather than nothing', () {
      final text = _packet(
        decisions: [_decision(decidedBy: null)],
      ).render();
      expect(text, contains('decided by not recorded'));
    });

    test('an empty record says "not recorded", never "none"', () {
      final text = _packet(decisions: const []).render();
      expect(text, contains('## Decisions on record'));
      final section = text.substring(
        text.indexOf('## Decisions on record'),
        text.indexOf('## Conversation so far'),
      );
      expect(section, contains('Not recorded'));
      // The distinction the whole feature turns on: nobody wrote anything
      // down, which is not evidence that nothing was decided. An empty
      // `changes` list is allowed to mean "the tree is clean"; an empty
      // decision record is never allowed to mean "nothing was settled".
      expect(section, contains('not the same as'));
      expect(section, contains('only written by explicit acts'));
      expect(section, isNot(contains('None')));
      expect(section, isNot(contains('No decisions')));
    });

    test('a record that could not be read is a different admission', () {
      final text = _packet(decisions: null).render();
      expect(text, contains('Not recorded'));
      expect(text, contains('could not be read'));
    });

    test('says how many decisions were left out, if any ever are', () {
      final text = _packet(
        decisions: [_decision()],
        omittedDecisions: 6,
      ).render();
      expect(text, contains('The last 1 of 7 decisions'));
    });
  });

  group('trimDecisions', () {
    List<HandoffDecision> many(int count, {int size = 20}) => [
      for (var i = 0; i < count; i++)
        HandoffDecision(
          kind: 'Constraint accepted',
          summary: '$i'.padRight(size, '.'),
          decidedBy: 'Claude Code',
          origin: 'a `decision_record` call',
        ),
    ];

    test('keeps the most recent, oldest first, and counts the rest', () {
      final result = trimDecisions(
        many(10),
        const HandoffDecisionBudget(maxDecisions: 3),
      );
      expect(result.decisions, hasLength(3));
      expect(result.omitted, 7);
      expect(result.decisions.first.summary, startsWith('7'));
      expect(result.decisions.last.summary, startsWith('9'));
    });

    test('reports what it cost, so the recap can be charged for it', () {
      final result = trimDecisions(many(4, size: 100));
      expect(result.decisions, hasLength(4));
      expect(result.cost, greaterThan(400));
    });

    test('truncates an over-long decision in the middle', () {
      final result = trimDecisions([
        HandoffDecision(
          kind: 'Approach rejected',
          summary: 'HEAD${'.' * 900}TAIL',
        ),
      ], const HandoffDecisionBudget(maxCharactersPerDecision: 120));
      final summary = result.decisions.single.summary;
      expect(summary, startsWith('HEAD'));
      expect(summary, endsWith('TAIL'));
      expect(summary, contains('trimmed for the handoff'));
    });

    test('leaves a record that already fits completely alone', () {
      final input = many(5);
      final result = trimDecisions(input);
      expect(result.decisions, input);
      expect(result.omitted, 0);
    });
  });

  group('the recap pays for the decisions, not the other way round', () {
    List<HandoffTurn> turns(int count) => [
      for (var i = 0; i < count; i++)
        HandoffTurn(speaker: 'User', text: '$i'.padRight(200, '.')),
    ];

    test('spending on decisions leaves less for the recap', () {
      const budget = HandoffRecapBudget(maxCharacters: 2000, maxTurns: 100);
      final whole = trimRecap(turns(40), budget);
      final squeezed = trimRecap(turns(40), budget.reducedBy(1500));

      // The decisions go first and are charged first, so what gives is the
      // quoted tail — which is the trade the whole feature is making.
      expect(squeezed.turns.length, lessThan(whole.turns.length));
      expect(squeezed.omitted, greaterThan(whole.omitted));
    });

    test('an over-spent budget still quotes the last turn', () {
      final result = trimRecap(
        turns(40),
        const HandoffRecapBudget(maxCharacters: 2000).reducedBy(999999),
      );
      expect(result.turns, hasLength(1));
      expect(result.turns.single.text, startsWith('39'));
    });
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

  group('the two rules — ownership and evidence', () {
    test('states the evidence rule, and that a packet is not evidence', () {
      final text = _packet().render();
      expect(text, contains('a command and what it printed'));
      expect(text, contains('"not checked yet"'));
      // The clause the rule exists for: a prior packet is a claim.
      expect(
        text,
        contains('A previous packet is a claim, not evidence'),
      );
      expect(text, contains('the files win'));
      // And the mismatch is reported rather than quietly corrected.
      expect(text, contains('worth reporting rather than quietly correcting'));
    });

    test('gives every section an owner, and says who may edit it', () {
      final text = _packet(
        decisions: [_decision()],
        recap: const [HandoffTurn(speaker: 'The user', text: 'Go.')],
        unresolvedTasks: const ['the parser'],
      ).render();

      // The quoted recap has no editors at all — an edited quotation is not
      // evidence any more.
      expect(
        text,
        contains(
          '_Owner: Claude Code and the user. No editors — if you disagree '
          'with something here, say so; do not rewrite it._',
        ),
      );
      // The decision record does: the receiving agent adds to it.
      expect(
        text,
        contains('_Owner: Claude Code and the user. May edit: Codex CLI'),
      );
      expect(text, contains('_Owner: the user.'));
      expect(text, contains('_Owner: Karmashala, read from git.'));
    });

    test('the ownership rule is stated once, above the sections', () {
      final text = _packet().render();
      expect(text, contains('Each section names its owner and who may edit'));
      expect(
        text.indexOf('Each section names its owner'),
        lessThan(text.indexOf('## Where this came from')),
      );
    });
  });

  group('the dead ends already ruled out', () {
    test('are their own section, above the rest of the record', () {
      final text = _packet(
        deadEnds: const [
          HandoffClaim(
            statement: 'An isolate pool for the parser.',
            evidence: 'lib/src/parser.dart:88 — deadlocks on Windows',
            attributedTo: 'Claude Code',
          ),
        ],
        decisions: [_decision()],
      ).render();

      expect(text, contains("## Don't do"));
      expect(text, contains('- **An isolate pool for the parser.**'));
      expect(text, contains('said by: Claude Code'));
      expect(
        text,
        contains('evidence: lib/src/parser.dart:88 — deadlocks on Windows'),
      );
      expect(
        text.indexOf("## Don't do"),
        lessThan(text.indexOf('## Decisions on record')),
      );
      // It is the receiving agent's to add to — that is the whole use of it.
      expect(text, contains('_Owner: Claude Code. May edit: Codex CLI'));
    });

    test('a claim with no evidence says "not checked yet"', () {
      final text = _packet(
        deadEnds: const [HandoffClaim(statement: 'Threads.')],
      ).render();
      expect(text, contains('evidence: not checked yet'));
      // And the attribution is never simply dropped.
      expect(text, contains('said by: not recorded'));
    });

    test('an empty list is not "nothing was ruled out"', () {
      final text = _packet(deadEnds: const []).render();
      expect(text, contains('Nothing was recorded as ruled out'));
      expect(
        text,
        contains('That is not the same as "nothing was ruled out"'),
      );
      expect(text, isNot(contains('None.')));
    });

    test('a record that could not be read says so, not "none"', () {
      final text = _packet(deadEnds: null).render();
      expect(text, contains('Could not be read'));
      expect(text, contains('before spending a turn re-deriving it'));
    });
  });


  group("the source agent's own brief", () {
    test('is absent entirely when nobody asked for one', () {
      // Declining has to leave the packet exactly as it was.
      expect(_packet().render(), isNot(contains('own words')));
    });

    test('is quoted, attributed, and marked as unchecked', () {
      final text = _packet(
        sourceBrief: const HandoffSourceBrief.written(
          'The parser is half done.\nThe Windows build is untested.',
        ),
      ).render();

      expect(text, contains("## In Claude Code's own words"));
      expect(text, contains('> The parser is half done.'));
      expect(text, contains('> The Windows build is untested.'));
      // Its words, said to be its words — the packet's one rule.
      expect(text, contains('Claude Code wrote this when the handoff was'));
      expect(text, contains('nobody has checked it'));
      // And the evidence rule reaches it like everything else.
      expect(text, contains('the evidence rule above applies'));
      expect(text, contains('the verbatim quotes further down'));
      // Quoted, so it has no editors.
      expect(
        text,
        contains('_Owner: Claude Code. No editors'),
      );
    });

    test('a brief that was asked for and not written says why', () {
      final text = _packet(
        sourceBrief: const HandoffSourceBrief.notWritten(
          'it had not answered when this stopped waiting.',
        ),
      ).render();

      expect(text, contains("## In Claude Code's own words"));
      expect(
        text,
        contains(
          'Claude Code was asked to write this and did not: it had not '
          'answered when this stopped waiting.',
        ),
      );
      // And nothing else in the packet is weaker for it.
      expect(text, contains('Nothing else in this packet depends on it'));
    });

    test('sits above the files and the record, not buried under them', () {
      final text = _packet(
        sourceBrief: const HandoffSourceBrief.written('Half done.'),
      ).render();
      expect(
        text.indexOf("## In Claude Code's own words"),
        lessThan(text.indexOf('## Files changed in the working tree')),
      );
    });

    test('the receiving prefix frames the work as inherited, not remembered', () {
      final text = _packet().render();
      expect(text, contains('Another model started this and has stopped'));
      expect(text, contains('Build on what it did rather than repeating it'));
      // And the half of Codex's framing that would be false here is not
      // claimed: nothing says the reader has the other model's tool state.
      expect(text, isNot(contains('tool state')));
    });

    test('the request is the compaction prompt, not a paraphrase', () {
      expect(
        kSourceBriefRequest,
        startsWith(
          'You are performing a CONTEXT CHECKPOINT COMPACTION. Create a '
          'handoff summary for another LLM that will resume the task.',
        ),
      );
      expect(kSourceBriefRequest, contains('- Current progress and key decisions made'));
      expect(kSourceBriefRequest, contains('- What remains to be done (clear next steps)'));
      expect(
        kSourceBriefRequest,
        endsWith('helping the next LLM seamlessly continue the work.'),
      );
    });
  });

}
