import 'dart:convert';

import 'package:agent_cli/process.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/git.dart';
import 'package:test/test.dart';

/// The checkpoint work a client asks the server's recorder to do (slice 2b):
/// capture, a run's base, a diff, a restore and the skip reasons, through
/// the envelope as JSON text.
void main() {
  final checkpoint = Checkpoint(
    id: 'c1',
    sessionId: 's1',
    repository: const EnvironmentPath(environmentId: 'local', path: '/r'),
    sequence: 3,
    treeSha: 'tree',
    commitSha: 'commit',
    parentCommitSha: null,
    headSha: 'head',
    reason: CheckpointReason.manual,
    label: 'kept',
    createdAt: DateTime.utc(2026, 9, 27, 9),
  );
  const file = FileChange(
    path: 'a.dart',
    type: FileChangeType.modified,
    staged: false,
    unstaged: true,
  );

  Map<String, Object?> overTheWire(Map<String, Object?> json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  DataReply<R> roundTrip<R>(DataRequest<R> request, R result) =>
      DataEnvelope.readAnswer(
        overTheWire(
          DataEnvelope.answer(4, request, DataReply(result, 9, const [])),
        ),
        request,
      );

  test('every request round-trips with its arguments', () {
    final requests = <DataRequest<Object?>>[
      const CheckpointCapture(
        's1',
        label: 'before the refactor',
        decidedBy: 'an agent in session s2',
        decidedBySessionId: 's2',
      ),
      const CheckpointCapture('s1'),
      const CheckpointCaptureBase(
        EnvironmentPath(environmentId: 'wsl', path: '/home/r'),
        runId: 'run1',
        label: 'before run',
      ),
      const CheckpointDiff('c1'),
      const CheckpointRestore('c1', confirm: true, paths: ['a.dart']),
      const CheckpointRestore('c1'),
      const CheckpointSkips(),
    ];
    for (final request in requests) {
      expect(request, isA<CheckpointWorkRequest<Object?>>());
      final read = DataEnvelope.readRequest(
        overTheWire(DataEnvelope.request(3, request)),
      );
      expect(read.refusal, isNull, reason: request.kind);
      expect(read.request!.kind, request.kind);
      expect(
        read.request!.argumentsToJson(),
        request.argumentsToJson(),
        reason: request.kind,
      );
    }
  });

  test('answers carry typed results', () {
    expect(
      roundTrip(const CheckpointCapture('s1'), checkpoint).value!.label,
      'kept',
    );
    expect(roundTrip(const CheckpointCapture('s1'), null).value, isNull);
    expect(
      roundTrip(const CheckpointDiff('c1'), 'diff --git').value,
      'diff --git',
    );
    expect(
      roundTrip(const CheckpointSkips(), {'s1': 'it has no repository'}).value,
      {'s1': 'it has no repository'},
    );
  });

  test('a restore answers its outcome, or throws its conflict', () {
    final done = roundTrip(
      const CheckpointRestore('c1'),
      CheckpointRestoreAnswer.restored(
        RestoreOutcome(
          restored: checkpoint,
          safetyCheckpoint: checkpoint,
          files: const [file],
          alreadyThere: false,
        ),
      ),
    ).value.outcomeOrThrow;
    expect(done.files.single.path, 'a.dart');
    expect(done.files.single.type, FileChangeType.modified);
    expect(done.safetyCheckpoint!.id, 'c1');
    expect(done.alreadyThere, isFalse);

    final refused = roundTrip(
      const CheckpointRestore('c1'),
      CheckpointRestoreAnswer.refused(
        CheckpointConflict(
          'The working tree has changed',
          safetyCheckpoint: checkpoint,
        ),
      ),
    ).value;
    expect(
      () => refused.outcomeOrThrow,
      throwsA(
        isA<CheckpointConflict>()
            .having((c) => c.message, 'message', 'The working tree has changed')
            .having((c) => c.safetyCheckpoint?.sequence, 'safety', 3),
      ),
    );
  });

  test('a skip reason is told, and so is its end', () {
    final text = jsonEncode(
      DataEnvelope.changes(
        const DataChanges(2, [
          CheckpointSkipChanged('s1', 'it has no repository to checkpoint'),
          CheckpointSkipChanged('s1', null),
        ]),
      ),
    );
    final back = DataEnvelope.readChanges(
      (jsonDecode(text) as Map).cast<String, Object?>(),
    ).changes.cast<CheckpointSkipChanged>();
    expect(back.first.reason, 'it has no repository to checkpoint');
    expect(back.last.sessionId, 's1');
    expect(back.last.reason, isNull);
  });

  test('a restore with paths that are not strings is refused', () {
    final read = DataEnvelope.readRequest({
      'id': 1,
      'kind': CheckpointRestore.name,
      'arguments': {
        'id': 'c1',
        'paths': [1],
      },
    });
    expect(read.refusal?.code, DataRefusalCode.invalid);
  });
}
