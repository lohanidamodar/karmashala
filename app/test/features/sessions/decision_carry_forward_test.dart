import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/sessions/application/decision_recorder.dart';
import 'package:karmashala/src/features/sessions/application/session_decision_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_store/database.dart';
import 'package:riverpod/riverpod.dart';

/// A handoff moves the work; the decision record has to move with it, or the
/// second continuation in a chain starts from nothing the first one learned.
void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = AppDatabase.memory();
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
  });
  tearDown(() {
    container.dispose();
    db.close();
  });

  DecisionRecorder recorder() => container.read(decisionRecorderProvider);
  DecisionRecord seed({
    String sessionId = 'src',
    String summary = 'The isolate pool deadlocked on Windows.',
    String? decidedBy = 'Claude Code',
    String? recordedBySessionId,
    DecisionKind kind = DecisionKind.approachRejected,
    DecisionOrigin origin = DecisionOrigin.verificationRun,
    String? originId = 'v-1',
    int minute = 0,
  }) => container
      .read(decisionRecordDaoProvider)
      .append(
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

  test('copies every row into the new session, oldest first', () {
    seed(summary: 'First');
    seed(summary: 'Second', minute: 5);

    expect(recorder().carryForward(from: 'src', into: 'dst'), 2);
    final carried = container.read(decisionRecordDaoProvider).forSession('dst');
    expect(carried.map((d) => d.summary), ['First', 'Second']);
    // The source keeps its own record: a handoff copies, it does not move.
    expect(
      container.read(decisionRecordDaoProvider).forSession('src'),
      hasLength(2),
    );
  });

  test('keeps who decided it and when, rather than restamping it as new', () {
    seed(minute: 7);
    recorder().carryForward(from: 'src', into: 'dst');

    final carried = container
        .read(decisionRecordDaoProvider)
        .forSession('dst')
        .single;
    expect(carried.decidedBy, 'Claude Code');
    expect(carried.recordedAt, DateTime.utc(2026, 8, 31, 12, 7));
    expect(carried.kind, DecisionKind.approachRejected);
    expect(carried.origin, DecisionOrigin.verificationRun);
    expect(carried.originId, 'v-1');
  });

  test('a row that named no recording session gains the one it came from', () {
    seed();
    recorder().carryForward(from: 'src', into: 'dst');
    // Where a reader goes to see the conversation the decision was made in.
    expect(
      container
          .read(decisionRecordDaoProvider)
          .forSession('dst')
          .single
          .recordedBySessionId,
      'src',
    );
  });

  test('a row that already named one keeps it through a second handoff', () {
    seed(recordedBySessionId: 'original');
    recorder().carryForward(from: 'src', into: 'dst');
    recorder().carryForward(from: 'dst', into: 'third');

    expect(
      container
          .read(decisionRecordDaoProvider)
          .forSession('third')
          .single
          .recordedBySessionId,
      'original',
    );
  });

  test('carrying nothing is not an error, and bumps nothing', () {
    final before = container.read(decisionsRevisionProvider);
    expect(recorder().carryForward(from: 'empty', into: 'dst'), 0);
    expect(container.read(decisionsRevisionProvider), before);
  });

  test('carrying a session into itself is refused, not doubled', () {
    seed();
    expect(recorder().carryForward(from: 'src', into: 'src'), 0);
    expect(
      container.read(decisionRecordDaoProvider).forSession('src'),
      hasLength(1),
    );
  });

  test('a carry that wrote rows tells the panel to re-read', () {
    seed();
    final before = container.read(decisionsRevisionProvider);
    recorder().carryForward(from: 'src', into: 'dst');
    expect(container.read(decisionsRevisionProvider), greaterThan(before));
  });
}
