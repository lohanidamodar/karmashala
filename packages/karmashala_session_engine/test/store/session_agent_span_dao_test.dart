import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import '../support/store_fixtures.dart';

/// `session_agent_spans`: span 0 written lazily at the first switch, the row
/// pointed at the new agent in the same step, and a switch back naming the
/// conversation the agent left.
void main() {
  late AppDatabase db;
  late SessionDao sessions;
  late SessionAgentSpanDao spans;
  final t1 = DateTime.utc(2026, 10, 3, 12);
  final t2 = DateTime.utc(2026, 10, 3, 13);

  setUp(() {
    db = AppDatabase.memory();
    seedWorkspace(db);
    db.execute(
      'INSERT INTO agent_installations '
      '(id, agent_kind, environment_id, executable_path, created_at) '
      "VALUES ('a2', 'codex', 'windows', 'codex.exe', ?);",
      [testTime.toIso8601String()],
    );
    sessions = SessionDao(db);
    spans = SessionAgentSpanDao(db);
    sessions.insert(session());
    sessions.updateExternalSessionId('s1', 'conv-a');
  });
  tearDown(() => db.close());

  test('a session that never switched has no spans', () {
    expect(spans.forSession('s1'), isEmpty);
    expect(spans.hasSpans('s1'), isFalse);
  });

  test('the first switch writes span 0 and span 1 and repoints the row', () {
    final next = spans.recordSwitch(
      session: sessions.getById('s1')!,
      toInstallationId: 'a2',
      toExternalSessionId: null,
      at: t1,
      firstMessageOrdinal: 4,
      carriedPacket: 'packet',
    );
    expect(next.seq, 1);
    expect(spans.forSession('s1'), [
      SessionAgentSpan(
        sessionId: 's1',
        seq: 0,
        agentInstallationId: 'a1',
        externalSessionId: 'conv-a',
        startedAt: testTime,
      ),
      SessionAgentSpan(
        sessionId: 's1',
        seq: 1,
        agentInstallationId: 'a2',
        startedAt: t1,
        firstMessageOrdinal: 4,
        carriedPacket: 'packet',
      ),
    ]);
    final row = sessions.getById('s1')!;
    expect(row.agentInstallationId, 'a2');
    expect(row.externalSessionId, isNull);
    expect(row.title, 'Work');
  });

  test('switching back keeps the leaving conversation and resumes the old', () {
    spans.recordSwitch(
      session: sessions.getById('s1')!,
      toInstallationId: 'a2',
      toExternalSessionId: null,
      at: t1,
    );
    sessions.updateExternalSessionId('s1', 'conv-b');
    spans.recordSwitch(
      session: sessions.getById('s1')!,
      toInstallationId: 'a1',
      toExternalSessionId: 'conv-a',
      at: t2,
    );
    final all = spans.forSession('s1');
    expect(all.map((s) => (s.seq, s.agentInstallationId, s.externalSessionId)), [
      (0, 'a1', 'conv-a'),
      (1, 'a2', 'conv-b'),
      (2, 'a1', 'conv-a'),
    ]);
    expect(sessions.getById('s1')!.externalSessionId, 'conv-a');
  });

  test('a span round-trips through json', () {
    final span = SessionAgentSpan(
      sessionId: 's1',
      seq: 2,
      agentInstallationId: 'a2',
      externalSessionId: 'x',
      startedAt: t2,
      firstMessageOrdinal: 7,
      carriedPacket: 'p',
    );
    expect(SessionAgentSpan.fromJson(span.toJson()), span);
  });
}
