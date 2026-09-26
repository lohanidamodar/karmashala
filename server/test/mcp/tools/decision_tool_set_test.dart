import 'package:karmashala_host/src/mcp/tools/decision_tool_set.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:test/test.dart';

import 'tool_harness.dart';

/// `decision_record`, run by the server (slice 2b). The one property under
/// test throughout: **a row exists only because somebody did something**, and
/// an agent may write only what it can assert on its own.
void main() {
  late ToolHarness h;
  late DecisionToolSet tools;

  setUp(() {
    h = ToolHarness();
    tools = DecisionToolSet(h.context);
  });
  tearDown(() => h.dispose());

  List<DecisionRecord> recordOf(String sessionId) =>
      DecisionRecordDao(h.db).forSession(sessionId);

  Future<Map<String, Object?>> record(
    Map<String, dynamic> arguments, [
    String? caller,
  ]) => h.map(tools, 'decision_record', arguments, caller);

  Matcher refusedWith(String words) => throwsA(
    isA<ArgumentError>().having((e) => '$e', 'text', contains(words)),
  );

  test('writes what the agent decided, in the agent\'s own words', () async {
    final answer = await record({
      'kind': 'rejected',
      'summary': 'The isolate pool deadlocked on Windows.',
      'detail': 'Two workers, both waiting on the same send port.',
    }, 's1');

    final decision = recordOf('s1').single;
    expect(decision.kind, DecisionKind.approachRejected);
    // Stored exactly as given. A gist would be a claim nobody made.
    expect(decision.summary, 'The isolate pool deadlocked on Windows.');
    expect(decision.detail, 'Two workers, both waiting on the same send port.');
    expect(decision.origin, DecisionOrigin.decisionTool);
    expect(decision.recordedBySessionId, 's1');
    // Attributed by name, because the packet's reader cannot resolve an id.
    expect(decision.decidedBy, 'Claude Code');
    expect(decision.sequence, 1);
    expect(answer, {
      'sessionId': 's1',
      'sequence': 1,
      'kind': 'approachRejected',
      'summary': 'The isolate pool deadlocked on Windows.',
      'decidedBy': 'Claude Code',
      'recordedAt': h.now.toIso8601String(),
    });
  });

  test('defaults to the calling session, and can name another', () async {
    await record({
      'kind': 'constraint',
      'summary': 'Windows is the primary target.',
    }, 's1');
    await record({
      'kind': 'constraint',
      'summary': "Recorded onto someone else's work.",
      'sessionId': 's1',
    }, 's2');

    expect(recordOf('s1'), hasLength(2));
    expect(recordOf('s2'), isEmpty);
    // Naming a target does not rewrite who asked.
    expect(recordOf('s1').last.recordedBySessionId, 's2');
  });

  test('an agent cannot forge an approval the user never gave', () async {
    for (final kind in const ['approval', 'verification', 'checkpoint']) {
      await expectLater(
        record({
          'kind': kind,
          'summary': 'The user said yes to everything.',
        }, 's1'),
        refusedWith('kind must be one of: constraint, rejected'),
        reason: kind,
      );
    }
    expect(recordOf('s1'), isEmpty);
  });

  test('a blank decision is refused rather than counted', () async {
    await expectLater(
      record({'kind': 'constraint', 'summary': '   '}, 's1'),
      refusedWith('summary is required'),
    );
    expect(recordOf('s1'), isEmpty);
  });

  test('a caller with no session of its own must name one', () async {
    await expectLater(
      record({'kind': 'constraint', 'summary': 'Anonymous.'}),
      refusedWith('not running inside a session'),
    );
  });

  test('a session that does not exist is the app\'s words', () async {
    await expectLater(
      record({
        'kind': 'constraint',
        'summary': 'Nowhere.',
        'sessionId': 'ghost',
      }, 's1'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          "The decision could not be written to ghost's record.",
        ),
      ),
    );
  });

  test('recording the same decision twice appends, never rewrites', () async {
    await record({'kind': 'constraint', 'summary': 'No isolates.'}, 's1');
    await record({'kind': 'constraint', 'summary': 'No isolates.'}, 's1');

    final rows = recordOf('s1');
    expect(rows, hasLength(2));
    expect(rows.first.sequence, 1);
    expect(rows.last.sequence, 2);
  });
}
