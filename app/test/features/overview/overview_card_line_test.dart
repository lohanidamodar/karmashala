import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:agent_cli/stream.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/overview/application/overview_card_line.dart';
import 'package:karmashala/src/features/overview/application/overview_reads.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

/// **What a session is doing, for a person**: the call's own words, then the
/// plan step, then the state in words — and a command never in the headline.
void main() {
  final now = DateTime.utc(2026, 10, 6, 12);
  const script =
      r'$sp = "$env:TEMP\x"; Set-Location $root; dart analyze > "$sp\a.txt"';

  AgentStatusReport report(
    AgentActivityStatus status, {
    AgentWaitKind waiting = AgentWaitKind.unrecorded,
    AgentToolAsk? ask,
    DateTime? waitingSince,
    List<String> inFlight = const [],
    List<String> evidence = const [],
    DateTime? evidenceAt,
  }) => AgentStatusReport(
    agentId: 'claude-code',
    sessionId: 'cli-1',
    status: status,
    observedAt: now,
    sourceModifiedAt: evidenceAt,
    source: AgentStatusSource.hook,
    waiting: waiting,
    toolAsk: ask,
    waitingSince: waitingSince,
    inFlight: inFlight,
    evidence: evidence,
  );

  OverviewActivity activity(
    AgentState state, {
    AgentStatusReport? status,
    Map<String, String> details = const {},
    DateTime? activityAt,
    OverviewGlance? glance,
  }) => overviewActivity(
    state: state,
    report: status,
    detailOf: (kind) => details[kind.name],
    activityAt: activityAt ?? now,
    now: now,
    glance: glance,
  );

  String line(
    AgentState state, {
    AgentStatusReport? status,
    Map<String, String> details = const {},
    DateTime? activityAt,
  }) => activity(
    state,
    status: status,
    details: details,
    activityAt: activityAt,
  ).headline;

  final working = report(AgentActivityStatus.working);
  final fourMinutesAgo = now.subtract(const Duration(minutes: 4));

  group('working, in order of preference', () {
    test('first the running call\'s own description, with its age', () {
      final out = activity(
        AgentState.working,
        status: report(AgentActivityStatus.working, inFlight: const [script]),
        glance: OverviewGlance(
          plan: const AgentPlan(
            items: [
              AgentPlanItem(
                text: 'Fix the peek',
                state: AgentPlanItemState.inProgress,
              ),
            ],
          ),
          open: [
            OverviewOpenCall(
              phrase: 'Run the analyzer',
              raw: script,
              since: fourMinutesAgo,
            ),
          ],
        ),
      );
      expect(out.headline, 'Run the analyzer · 4m');
      expect(out.raw, script);
    });

    test('then the plan step, the command only folded away', () {
      final out = activity(
        AgentState.working,
        status: working,
        glance: OverviewGlance(
          plan: const AgentPlan(
            items: [
              AgentPlanItem(
                text: 'Map the code',
                state: AgentPlanItemState.completed,
              ),
              AgentPlanItem(
                text: 'Write the tests',
                state: AgentPlanItemState.inProgress,
              ),
              AgentPlanItem(text: 'Ship', state: AgentPlanItemState.pending),
            ],
          ),
          open: [OverviewOpenCall(raw: script, since: fourMinutesAgo)],
        ),
      );
      expect(out.headline, 'Step 2/3: Write the tests');
      expect(out.raw, script);
    });

    test('then the state in words: a raw command reads as running one', () {
      final out = activity(
        AgentState.working,
        status: working,
        glance: OverviewGlance(
          open: [
            OverviewOpenCall(
              raw: script,
              since: fourMinutesAgo,
              background: true,
            ),
          ],
        ),
      );
      expect(out.headline, 'Running a background command · 4m');
      expect(out.raw, script);
    });

    test('a hook\'s in-flight command is never the headline', () {
      final out = activity(
        AgentState.working,
        status: report(
          AgentActivityStatus.working,
          inFlight: const [script, 'k6 run load.js'],
        ),
      );
      expect(out.headline, 'Running a background command +1');
      expect(out.raw, script);
      expect(
        activity(
          AgentState.working,
          status: report(
            AgentActivityStatus.working,
            inFlight: const ['Load test the relay'],
          ),
        ).headline,
        'In the background: Load test the relay',
      );
    });

    test('its own last words, unless they are a command', () {
      expect(
        line(
          AgentState.working,
          status: report(
            AgentActivityStatus.working,
            evidence: const ['Reading app/lib', ''],
          ),
        ),
        'Reading app/lib',
      );
      final out = activity(
        AgentState.working,
        status: report(AgentActivityStatus.working, evidence: const [script]),
      );
      expect(out.headline, 'Working');
      expect(out.raw, script);
      expect(line(AgentState.working, status: working), 'Working');
    });
  });

  test('an approval says what it asks in words, and for how long', () {
    final waiting = now.subtract(const Duration(minutes: 4));
    AgentStatusReport asking(Map<String, Object?> input) => report(
      AgentActivityStatus.awaitingApproval,
      waiting: AgentWaitKind.approval,
      ask: AgentToolAsk(toolName: 'Bash', input: input, at: now),
      waitingSince: waiting,
    );
    final described = activity(
      AgentState.needsYou,
      status: asking(const {
        'command': script,
        'description': 'Run the analyzer',
      }),
    );
    expect(described.headline, 'Asks to: Run the analyzer · 4m');
    expect(described.raw, script);
    final bare = activity(
      AgentState.needsYou,
      status: asking(const {'command': 'flutter test'}),
    );
    expect(bare.headline, 'Asks to run a command · 4m');
    expect(bare.raw, 'flutter test');
  });

  test('a question, and a wait nobody could word', () {
    expect(
      line(
        AgentState.needsYou,
        status: report(
          AgentActivityStatus.awaitingApproval,
          waiting: AgentWaitKind.question,
        ),
      ),
      'Asks a question',
    );
    expect(line(AgentState.needsYou), 'Waiting on you');
    expect(
      line(AgentState.needsYou, details: {'needsApproval': 'Allow write?'}),
      'Asks: Allow write?',
    );
  });

  test('quiet says how long nothing came', () {
    expect(
      line(
        AgentState.quiet,
        status: report(
          AgentActivityStatus.working,
          evidenceAt: now.subtract(const Duration(minutes: 22)),
        ),
      ),
      'Nothing new for 22m',
    );
  });

  test('failed, ready and done use the inbox words when there are any', () {
    expect(
      line(AgentState.failed, details: {'failed': 'rate_limit'}),
      'Failed: rate_limit',
    );
    expect(line(AgentState.failed), 'Failed');
    expect(
      line(AgentState.ready, details: {'finished': 'tests pass'}),
      'tests pass',
    );
    expect(
      line(
        AgentState.ready,
        activityAt: now.subtract(const Duration(minutes: 9)),
      ),
      'Finished its turn · waiting for you',
    );
    expect(
      line(AgentState.ended, details: {'followUp': 'merged r22'}),
      'Done: merged r22',
    );
    expect(
      line(
        AgentState.ended,
        activityAt: now.subtract(const Duration(hours: 3)),
      ),
      'Ended 3h ago',
    );
  });

  group('one server read', () {
    TranscriptMessage call(
      String name,
      Map<String, Object?> input, {
      bool open = true,
      BackgroundRun? background,
    }) => TranscriptMessage(
      role: 'tool',
      text: name,
      tool: toolActivityFor(name, input),
      at: fourMinutesAgo,
      pendingToolUseId: open && background == null ? 'call-1' : null,
      background: background,
    );

    test('names the open calls in words and keeps the plan', () {
      const plan = AgentPlan(
        items: [
          AgentPlanItem(text: 'Ship', state: AgentPlanItemState.inProgress),
        ],
      );
      final glance = overviewGlanceOf(
        TranscriptPage(
          sessionId: 's',
          generation: 'g',
          revision: 1,
          total: 9,
          from: 8,
          messages: [
            call('Bash', const {
              'command': script,
              'description': 'Run the analyzer',
            }),
          ],
          digest: TranscriptDigest(
            end: 8,
            plan: TranscriptUpdate(
              2,
              TranscriptMessage(
                role: 'tool',
                text: 'plan',
                tool: const ToolActivity(name: 'TodoWrite', plan: plan),
              ),
            ),
            pending: [
              TranscriptUpdate(
                5,
                call(
                  'Bash',
                  const {'command': 'k6 run load.js', 'run_in_background': true},
                  background: const BackgroundRun(
                    id: 'b1',
                    kind: BackgroundRunKind.command,
                    state: BackgroundRunState.running,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      expect(glance.plan, plan);
      expect(glance.open, hasLength(2));
      expect(glance.open.first.phrase, isNull);
      expect(glance.open.first.raw, 'k6 run load.js');
      expect(glance.open.first.background, isTrue);
      expect(glance.open.last.phrase, 'Run the analyzer');
      expect(glance.open.last.raw, isNull);
    });
  });

  test('a command is told from words', () {
    for (final command in [
      script,
      'flutter test --exclude-tags=live-ssh',
      'k6 run load.js',
      'git status',
      'tail -f relay.log',
      'a\nb',
    ]) {
      expect(looksLikeCommand(command), isTrue, reason: command);
    }
    for (final words in [
      'Run the analyzer',
      'Load test the relay',
      'Writing tests in app/test/features/overview',
      'background work',
    ]) {
      expect(looksLikeCommand(words), isFalse, reason: words);
    }
  });
}
