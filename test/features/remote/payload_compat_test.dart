/// The version-discipline proof for Loop 73's payload additions: agent label,
/// whereabouts, last activity, delivery stage and the imported flag are
/// **additive JSON** — an old companion decodes a new host's payload by
/// ignoring the extras, and a new companion decodes an old host's payload by
/// answering null/false for what is not there. Both directions are pinned
/// here, through the raw snapshot and through a sealed-shape envelope.
library;

import 'package:chitragupta/src/features/remote/domain/remote_payloads.dart';
import 'package:chitragupta/src/features/remote/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final rich = RemoteSessionSnapshot(
    sessionId: 's1',
    title: 'Fix the tests',
    status: 'running',
    attention: 'needs_approval',
    stage: 'pushed',
    repositoryId: 'r1',
    repositoryName: 'popupbits',
    createdAt: '2026-08-31T10:00:00.000Z',
    agentLabel: 'Claude Code  ·  running',
    whereabouts: 'running here',
    lastActivityAt: '2026-08-31T10:05:00.000Z',
    imported: false,
  );

  group('new companion, old host (fields absent)', () {
    test('a minimal payload decodes with honest nothings', () {
      final snapshot = RemoteSessionSnapshot.fromJson(const {
        'sessionId': 's1',
        'title': 'Fix the tests',
        'status': 'running',
      });

      expect(snapshot.agentLabel, isNull);
      expect(snapshot.whereabouts, isNull);
      expect(snapshot.lastActivityAt, isNull);
      expect(snapshot.stage, isNull);
      expect(snapshot.imported, isFalse);
    });

    test('an old host frame carried through the envelope decodes', () {
      final envelope = Envelope.of(
        FrameType.sessionChanged,
        seq: 1,
        payload: const {
          'sessionId': 's1',
          'title': 'Fix the tests',
          'status': 'idle',
        },
      );

      final decoded = Envelope.fromBytes(envelope.toBytes());
      final snapshot = RemoteSessionSnapshot.fromJson(decoded.payload);

      expect(snapshot.status, 'idle');
      expect(snapshot.imported, isFalse);
      expect(snapshot.agentLabel, isNull);
    });
  });

  group('old companion, new host (extra fields ignored)', () {
    test('unknown keys — this loop\'s and any future one\'s — are '
        'skipped without complaint', () {
      // What an even-newer host might send: everything we emit today plus
      // keys nobody has heard of. A decoder that survives these survives
      // this loop's additions on an old build by the same mechanism.
      final json = rich.toJson()
        ..addAll({
          'futureFact': 'zettabyte',
          'nested': {'deep': true},
          'numbers': [1, 2, 3],
        });

      final snapshot = RemoteSessionSnapshot.fromJson(json);

      expect(snapshot, rich);
    });

    test('wrongly typed new fields degrade to null, never throw', () {
      final json = rich.toJson()
        ..['agentLabel'] = 42
        ..['whereabouts'] = ['not', 'a', 'string']
        ..['lastActivityAt'] = false
        ..['imported'] = 'yes';

      final snapshot = RemoteSessionSnapshot.fromJson(json);

      expect(snapshot.agentLabel, isNull);
      expect(snapshot.whereabouts, isNull);
      expect(snapshot.lastActivityAt, isNull);
      // Anything but a literal true reads as false — a claim must be exact.
      expect(snapshot.imported, isFalse);
    });
  });

  group('the new shape itself', () {
    test('round-trips every added field', () {
      expect(RemoteSessionSnapshot.fromJson(rich.toJson()), rich);
    });

    test('imported round-trips, and is omitted when false', () {
      final imported = RemoteSessionSnapshot(
        sessionId: 'i1',
        title: 'old chat',
        status: 'imported',
        imported: true,
      );

      expect(RemoteSessionSnapshot.fromJson(imported.toJson()).imported, true);
      // Absent-when-false keeps the old shape byte-compatible for old rows.
      expect(rich.toJson().containsKey('imported'), isFalse);
    });

    test('copyWith(stage:) — the host api\'s enrichment — keeps the new '
        'fields', () {
      final staged = rich.copyWith(stage: 'merged');

      expect(staged.stage, 'merged');
      expect(staged.agentLabel, rich.agentLabel);
      expect(staged.whereabouts, rich.whereabouts);
      expect(staged.lastActivityAt, rich.lastActivityAt);
      expect(staged.imported, rich.imported);
    });

    test('a rich frame through the envelope arrives whole', () {
      final envelope = Envelope.of(
        FrameType.sessionChanged,
        seq: 7,
        payload: rich.toJson(),
      );

      final decoded = Envelope.fromBytes(envelope.toBytes());

      expect(RemoteSessionSnapshot.fromJson(decoded.payload), rich);
    });
  });
}
