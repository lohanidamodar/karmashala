import 'package:agent_cli/descriptors.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/overview/application/overview_card_line.dart';

/// **A card's one line of context**: what it is doing or why it is there,
/// from what the app already holds — never a guess.
void main() {
  final now = DateTime.utc(2026, 10, 6, 12);

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

  String? line(
    AgentState state, {
    AgentStatusReport? status,
    Map<String, String> details = const {},
    DateTime? activityAt,
  }) => overviewContextLine(
    state: state,
    report: status,
    detailOf: (kind) => details[kind.name],
    activityAt: activityAt ?? now,
    now: now,
  );

  test('an approval says what it asks, and for how long', () {
    final ask = AgentToolAsk(
      toolName: 'Bash',
      input: const {'command': 'flutter test'},
      at: now,
    );
    expect(
      line(
        AgentState.needsYou,
        status: report(
          AgentActivityStatus.awaitingApproval,
          waiting: AgentWaitKind.approval,
          ask: ask,
          waitingSince: now.subtract(const Duration(minutes: 4)),
        ),
      ),
      'asks: run flutter test · 4m',
    );
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
      'asks a question',
    );
    expect(line(AgentState.needsYou), 'waiting on you');
    expect(
      line(AgentState.needsYou, details: {'needsApproval': 'Allow write?'}),
      'asks: Allow write?',
    );
  });

  test('working names its background run, or its own last words', () {
    expect(
      line(
        AgentState.working,
        status: report(
          AgentActivityStatus.working,
          inFlight: const ['flutter test', 'dart analyze'],
        ),
      ),
      'running flutter test +1',
    );
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
    expect(
      line(AgentState.working, status: report(AgentActivityStatus.working)),
      'working',
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
      'nothing new for 22m',
    );
  });

  test('failed, ready and done use the inbox words when there are any', () {
    expect(
      line(AgentState.failed, details: {'failed': 'rate_limit'}),
      'failed: rate_limit',
    );
    expect(line(AgentState.failed), 'failed');
    expect(
      line(AgentState.ready, details: {'finished': 'tests pass'}),
      'tests pass',
    );
    expect(
      line(
        AgentState.ready,
        activityAt: now.subtract(const Duration(minutes: 9)),
      ),
      'ready · 9m',
    );
    expect(
      line(AgentState.ended, details: {'followUp': 'merged r22'}),
      'done: merged r22',
    );
    expect(
      line(
        AgentState.ended,
        activityAt: now.subtract(const Duration(hours: 3)),
      ),
      'ended 3h ago',
    );
  });
}
