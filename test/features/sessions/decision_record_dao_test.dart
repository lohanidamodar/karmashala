import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/features/sessions/data/decision_record_dao.dart';
import 'package:karmashala_session/events.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late DecisionRecordDao dao;

  setUp(() {
    db = AppDatabase.memory();
    dao = DecisionRecordDao(db);
  });
  tearDown(() => db.close());

  DecisionRecord decision({
    String sessionId = 's-1',
    DecisionKind kind = DecisionKind.approachRejected,
    String summary = 'The isolate pool deadlocked on Windows.',
    DecisionOrigin origin = DecisionOrigin.decisionTool,
    String? originId,
    String? decidedBy = 'Claude Code',
    int minute = 0,
  }) => DecisionRecord(
    sessionId: sessionId,
    kind: kind,
    summary: summary,
    origin: origin,
    originId: originId,
    decidedBy: decidedBy,
    recordedAt: DateTime.utc(2026, 8, 31, 12, minute),
  );

  group('append', () {
    test('numbers a session\'s decisions from one, in its own chain', () {
      expect(dao.append(decision()).sequence, 1);
      expect(dao.append(decision()).sequence, 2);
      // Another session's chain starts again: sequence is a position in one
      // record, not a global clock.
      expect(dao.append(decision(sessionId: 's-2')).sequence, 1);
      expect(dao.append(decision()).sequence, 3);
    });

    test('returns the stored row, with the id the database gave it', () {
      final stored = dao.append(decision());
      expect(stored.id, isNotNull);
      expect(dao.forSession('s-1').single.id, stored.id);
    });

    test('reads back everything it was given, oldest first', () {
      dao.append(
        decision(
          kind: DecisionKind.verificationVerdict,
          summary: 'Pass — the login page renders.',
          origin: DecisionOrigin.verificationRun,
          originId: 'v-1',
          decidedBy: 'Codex CLI',
        ),
      );
      dao.append(decision(minute: 5, summary: 'No isolates.'));

      final rows = dao.forSession('s-1');
      expect(rows.map((d) => d.summary), [
        'Pass — the login page renders.',
        'No isolates.',
      ]);
      expect(rows.first.kind, DecisionKind.verificationVerdict);
      expect(rows.first.origin, DecisionOrigin.verificationRun);
      expect(rows.first.originId, 'v-1');
      expect(rows.first.decidedBy, 'Codex CLI');
      expect(rows.first.recordedAt, DateTime.utc(2026, 8, 31, 12));
    });

    test('counts what a session has recorded', () {
      expect(dao.countForSession('s-1'), 0);
      dao.append(decision());
      dao.append(decision());
      expect(dao.countForSession('s-1'), 1 + 1);
      expect(dao.countForSession('s-2'), 0);
    });
  });

  group('append-only', () {
    test('writing the same decision twice leaves the first one alone', () {
      final first = dao.append(decision(summary: 'Windows only.'));
      final second = dao.append(decision(summary: 'Windows only.', minute: 40));

      // Two rows, not one rewritten one. The record is a history of what was
      // decided, and a second identical write is a second act — collapsing
      // them would silently drop the time at which it was re-affirmed.
      final rows = dao.forSession('s-1');
      expect(rows.length, 2);
      expect(rows.first.id, first.id);
      expect(rows.first.sequence, 1);
      expect(rows.first.recordedAt, DateTime.utc(2026, 8, 31, 12));
      expect(rows.last.id, second.id);
      expect(rows.last.sequence, 2);
      expect(rows.last.recordedAt, DateTime.utc(2026, 8, 31, 12, 40));
    });

    test('a later decision that contradicts an earlier one leaves it '
        'standing', () {
      dao.append(decision(summary: 'Isolates are out.'));
      final before = dao.forSession('s-1').single;

      dao.append(
        decision(
          kind: DecisionKind.constraintAccepted,
          summary: 'Isolates are back in.',
          minute: 30,
        ),
      );

      // The record is a history, not a current position. Whoever reads the
      // packet needs to see that this was reversed and when — which is the one
      // thing an in-place edit would destroy.
      final after = dao.forSession('s-1');
      expect(after.length, 2);
      expect(after.first.id, before.id);
      expect(after.first.summary, 'Isolates are out.');
      expect(after.first.kind, before.kind);
      expect(after.first.recordedAt, before.recordedAt);
    });
  });

  group('the origin is a pointer, never a join', () {
    test('a decision whose origin is gone still reads back', () {
      dao.append(
        decision(
          kind: DecisionKind.checkpointMarked,
          origin: DecisionOrigin.checkpoint,
          // No such checkpoint exists, and nothing here ever looks.
          originId: 'c-pruned',
        ),
      );
      final row = dao.forSession('s-1').single;
      expect(row.origin, DecisionOrigin.checkpoint);
      expect(row.originId, 'c-pruned');
    });

    test('an act that left no record of its own says so with a null id', () {
      dao.append(
        decision(
          kind: DecisionKind.approvalGranted,
          origin: DecisionOrigin.approvalPrompt,
          decidedBy: 'the user',
        ),
      );
      expect(dao.forSession('s-1').single.originId, isNull);
    });
  });

  group('kinds', () {
    test('every kind survives a round trip', () {
      for (final kind in DecisionKind.values) {
        // `unrecognised` is a read-only state: nothing writes it.
        if (kind == DecisionKind.unrecognised) continue;
        dao.append(decision(sessionId: kind.name, kind: kind));
        expect(dao.forSession(kind.name).single.kind, kind);
      }
    });

    test('a kind this build does not know reads as unrecognised, not as '
        'something else', () {
      db.execute(
        'INSERT INTO session_decisions '
        '(session_id, sequence, kind, summary, origin_kind, recorded_at) '
        'VALUES (?, ?, ?, ?, ?, ?);',
        [
          's-9',
          1,
          'somethingLater',
          'x',
          'decisionTool',
          '2026-01-01T00:00:00Z',
        ],
      );
      // Never folded into a neighbour: a wrong heading over a real decision is
      // worse than an admission that the heading is unreadable.
      expect(dao.forSession('s-9').single.kind, DecisionKind.unrecognised);
    });

    test('an origin this build does not know reads as unrecognised', () {
      db.execute(
        'INSERT INTO session_decisions '
        '(session_id, sequence, kind, summary, origin_kind, recorded_at) '
        'VALUES (?, ?, ?, ?, ?, ?);',
        [
          's-8',
          1,
          'approachRejected',
          'x',
          'somethingLater',
          '2026-01-01T00:00:00Z',
        ],
      );
      expect(dao.forSession('s-8').single.origin, DecisionOrigin.unrecognised);
    });
  });
}
