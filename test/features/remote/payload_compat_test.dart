/// The version-discipline proof for Loop 73's payload additions: agent label,
/// whereabouts, last activity, delivery stage and the imported flag are
/// **additive JSON** — an old companion decodes a new host's payload by
/// ignoring the extras, and a new companion decodes an old host's payload by
/// answering null/false for what is not there. Both directions are pinned
/// here, through the raw snapshot and through a sealed-shape envelope.
library;

import 'package:karmashala/src/features/remote/domain/remote_payloads.dart';
import 'package:karmashala/src/features/remote/protocol.dart';
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
      // Not "nothing may be attached" — *we were never told*, which is why the
      // phone offers no button rather than showing a refusal it invented.
      expect(snapshot.attachments, isNull);
    });

    test('a host that says nothing may be attached says why', () {
      final snapshot = RemoteSessionSnapshot.fromJson(const {
        'sessionId': 's1',
        'title': 'Fix the tests',
        'status': 'running',
        'attach': {
          'types': <String>[],
          'max': 0,
          'why': 'Antigravity cannot be handed a file.',
        },
      });

      expect(snapshot.attachments, isNotNull);
      expect(snapshot.attachments!.allowsAnything, isFalse);
      expect(snapshot.attachments!.refusal, contains('Antigravity'));
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

  group("loop 80's fields are additive the same way", () {
    final placed = RemoteSessionSnapshot(
      sessionId: 's1',
      title: 'Fix the tests',
      status: 'running',
      projectId: 'p1',
      projectName: 'popupbits',
      projectPath: r'C:\work\popupbits',
      pinned: true,
      folderMissing: true,
      subPath: 'projects/app',
      worktree: r'C:\work\popupbits\wt-app',
      branch: 'feature/x',
    );

    test('an old host says none of them, and nothing is invented', () {
      final snapshot = RemoteSessionSnapshot.fromJson(const {
        'sessionId': 's1',
        'title': 'Fix the tests',
        'status': 'running',
      });

      expect(snapshot.projectId, isNull);
      expect(snapshot.projectName, isNull);
      expect(snapshot.projectPath, isNull);
      expect(snapshot.subPath, isNull);
      expect(snapshot.worktree, isNull);
      expect(snapshot.branch, isNull);
      // Both booleans read false, which is "no claim", not "we checked".
      expect(snapshot.pinned, isFalse);
      expect(snapshot.folderMissing, isFalse);
    });

    test('they round-trip, and the false booleans stay off the wire', () {
      expect(RemoteSessionSnapshot.fromJson(placed.toJson()), placed);
      expect(rich.toJson().containsKey('pinned'), isFalse);
      expect(rich.toJson().containsKey('folderMissing'), isFalse);
      expect(rich.toJson().containsKey('projectId'), isFalse);
    });

    test('wrongly typed values degrade rather than throw', () {
      final json = placed.toJson()
        ..['projectName'] = 7
        ..['subPath'] = ['not', 'a', 'string']
        ..['branch'] = false
        ..['pinned'] = 'yes'
        ..['folderMissing'] = 1;

      final snapshot = RemoteSessionSnapshot.fromJson(json);

      expect(snapshot.projectName, isNull);
      expect(snapshot.subPath, isNull);
      expect(snapshot.branch, isNull);
      expect(snapshot.pinned, isFalse);
      expect(snapshot.folderMissing, isFalse);
    });

    test("copyWith(stage:) — the api's enrichment — keeps them", () {
      final staged = placed.copyWith(stage: 'merged');

      expect(staged.projectId, 'p1');
      expect(staged.projectPath, placed.projectPath);
      expect(staged.pinned, isTrue);
      expect(staged.folderMissing, isTrue);
      expect(staged.subPath, 'projects/app');
      expect(staged.worktree, placed.worktree);
      expect(staged.branch, 'feature/x');
    });
  });

  group("loop 83's host.status relays are additive the same way", () {
    // A relay set is a hint about WHERE to meet, never about WHO answers: the
    // rendezvous is derived from the device key, so an old build that ignores
    // these keys loses a convenience and nothing else.
    final announced = RemoteHostStatus(
      versions: kSupportedVersions,
      hostName: 'Desktop',
      relays: [
        Uri.parse('ws://192.168.1.20:8787'),
        Uri.parse('wss://relay.popupbits.com'),
      ],
      lanHint: '192.168.1.20:47653',
    );

    test('old companion, new host: the greeting still decodes to a version '
        'range and a name', () {
      final decoded = Envelope.fromBytes(
        Envelope.of(FrameType.hostStatus, seq: 1, payload: announced.toJson())
            .toBytes(),
      );

      // Exactly the two keys a pre-Loop-83 build reads.
      expect(decoded.payload['versions'], isA<Map<String, Object?>>());
      expect(decoded.payload['host'], 'Desktop');
    });

    test('new companion, old host: no relays means none are invented', () {
      final decoded = Envelope.fromBytes(
        Envelope.of(
          FrameType.hostStatus,
          seq: 1,
          payload: {'versions': kSupportedVersions.toJson(), 'host': 'Desktop'},
        ).toBytes(),
      );

      final status = RemoteHostStatus.fromJson(decoded.payload);

      expect(status.relays, isEmpty);
      expect(status.lanHint, isNull);
      expect(status.hostName, 'Desktop');
    });

    test('the whole announcement survives the envelope', () {
      final decoded = Envelope.fromBytes(
        Envelope.of(FrameType.hostStatus, seq: 9, payload: announced.toJson())
            .toBytes(),
      );

      final status = RemoteHostStatus.fromJson(decoded.payload);

      expect(status.relays, announced.relays);
      expect(status.lanHint, announced.lanHint);
    });
  });

  group("an approval request's wait kind is additive too", () {
    test('an old host names none, and the phone assumes nothing', () {
      // The bug this field exists for: that host sent approve/deny keys for
      // any session that had stopped for the user, including one merely
      // sitting at its own prompt. A new phone can only read what it is told,
      // and what it is told here is nothing.
      final request = RemoteApprovalRequest.fromJson(const {
        'sessionId': 's1',
        'evidence': ['Run the tests?'],
        'approve': 'Approve',
      });

      expect(request.waiting, RemoteWaitKind.unrecorded);
      expect(request.approveLabel, 'Approve');
    });

    test('a word this build has never heard reads as unrecorded', () {
      final request = RemoteApprovalRequest.fromJson(const {
        'sessionId': 's1',
        'waiting': 'elicitation',
      });

      expect(request.waiting, RemoteWaitKind.unrecorded);
    });

    test('each kind round-trips through the envelope', () {
      for (final kind in RemoteWaitKind.values) {
        final decoded = Envelope.fromBytes(
          Envelope.of(
            FrameType.approvalRequested,
            seq: 11,
            payload: RemoteApprovalRequest(
              sessionId: 's1',
              evidence: const ['Run the tests?'],
              waiting: kind,
              approveLabel: kind == RemoteWaitKind.approval ? 'Approve' : null,
            ).toJson(),
          ).toBytes(),
        );

        final request = RemoteApprovalRequest.fromJson(decoded.payload);

        expect(request.waiting, kind, reason: kind.wire);
        expect(request.evidence, ['Run the tests?']);
      }
    });
  });
}
