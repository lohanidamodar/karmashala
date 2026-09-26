import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/application/decision_recorder.dart';
import 'package:karmashala/src/features/sessions/application/session_decision_providers.dart';
import 'package:karmashala_session/events.dart';
import 'package:riverpod/riverpod.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';

/// A handoff moves the work; the decision record has to move with it, or the
/// second continuation in a chain starts from nothing the first one learned.
void main() {
  late FakeDataServer server;
  late ProviderContainer container;

  setUp(() async {
    server = FakeDataServer();
    for (final id in ['src', 'dst', 'third', 'empty']) {
      server.sessionRows.insert(session(id: id));
    }
    container = ProviderContainer(overrides: [await server.override()]);
  });
  tearDown(() => container.dispose());

  DecisionRecorder recorder() => container.read(decisionRecorderProvider);
  List<DecisionRecord> recordOf(String sessionId) =>
      server.decisionRows.forSession(sessionId);
  DecisionRecord seed({
    String sessionId = 'src',
    String summary = 'The isolate pool deadlocked on Windows.',
    String? decidedBy = 'Claude Code',
    String? recordedBySessionId,
    DecisionKind kind = DecisionKind.approachRejected,
    DecisionOrigin origin = DecisionOrigin.verificationRun,
    String? originId = 'v-1',
    int minute = 0,
  }) => server.decisionRows.append(
    DecisionRecord(
      sessionId: sessionId,
      kind: kind,
      summary: summary,
      decidedBy: decidedBy,
      recordedBySessionId: recordedBySessionId,
      origin: origin,
      originId: originId,
      recordedAt: DateTime.utc(2026, 8, 31, 12, minute),
    ),
  );

  test('copies every row into the new session, oldest first', () async {
    seed(summary: 'First');
    seed(summary: 'Second', minute: 5);

    expect(await recorder().carryForward(from: 'src', into: 'dst'), 2);
    expect(recordOf('dst').map((d) => d.summary), ['First', 'Second']);
    // The source keeps its own record: a handoff copies, it does not move.
    expect(recordOf('src'), hasLength(2));
  });

  test(
    'keeps who decided it and when, rather than restamping it as new',
    () async {
      seed(minute: 7);
      await recorder().carryForward(from: 'src', into: 'dst');

      final carried = recordOf('dst').single;
      expect(carried.decidedBy, 'Claude Code');
      expect(carried.recordedAt, DateTime.utc(2026, 8, 31, 12, 7));
      expect(carried.kind, DecisionKind.approachRejected);
      expect(carried.origin, DecisionOrigin.verificationRun);
      expect(carried.originId, 'v-1');
    },
  );

  test(
    'a row that named no recording session gains the one it came from',
    () async {
      seed();
      await recorder().carryForward(from: 'src', into: 'dst');
      // Where a reader goes to see the conversation the decision was made in.
      expect(recordOf('dst').single.recordedBySessionId, 'src');
    },
  );

  test(
    'a row that already named one keeps it through a second handoff',
    () async {
      seed(recordedBySessionId: 'original');
      await recorder().carryForward(from: 'src', into: 'dst');
      await recorder().carryForward(from: 'dst', into: 'third');

      expect(recordOf('third').single.recordedBySessionId, 'original');
    },
  );

  test('carrying nothing is not an error, and bumps nothing', () async {
    final before = container.read(decisionsRevisionProvider);
    expect(await recorder().carryForward(from: 'empty', into: 'dst'), 0);
    expect(container.read(decisionsRevisionProvider), before);
  });

  test('carrying a session into itself is refused, not doubled', () async {
    seed();
    expect(await recorder().carryForward(from: 'src', into: 'src'), 0);
    expect(recordOf('src'), hasLength(1));
  });

  test('a carry that wrote rows tells the panel to re-read', () async {
    seed();
    final before = container.read(decisionsRevisionProvider);
    await recorder().carryForward(from: 'src', into: 'dst');
    expect(container.read(decisionsRevisionProvider), greaterThan(before));
  });
}
