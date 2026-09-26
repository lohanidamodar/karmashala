import 'dart:convert';

import 'package:agent_cli/process.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala_git/git.dart';
import 'package:test/test.dart';

/// **A restore says what the service refused, and what it cannot do** — one
/// function for the rule and its sentence, and the answer a client is sent.
void main() {
  Checkpoint checkpoint(int sequence) => Checkpoint(
    id: 'c$sequence',
    sessionId: 's1',
    repository: const EnvironmentPath(environmentId: 'local', path: '/r'),
    sequence: sequence,
    treeSha: 't$sequence',
    commitSha: 'k$sequence',
    parentCommitSha: null,
    headSha: null,
    reason: CheckpointReason.safety,
    createdAt: DateTime.utc(2026, 9, 27),
  );
  const file = FileChange(
    path: 'lib/a.dart',
    type: FileChangeType.modified,
    staged: false,
    unstaged: true,
  );

  test('a refusal is one function, and it names the half we cannot undo', () {
    expect(
      checkpointRestoreRefusal(
        treeMovedSinceLastCheckpoint: false,
        safetySequence: null,
      ),
      isNull,
    );
    final refusal = checkpointRestoreRefusal(
      treeMovedSinceLastCheckpoint: true,
      safetySequence: 7,
    );
    expect(refusal, contains('checkpoint 7'));
    expect(refusal, contains(kRestoreLeavesTheConversation));
    expect(
      checkpointRestoreRefusal(
        treeMovedSinceLastCheckpoint: true,
        safetySequence: null,
      ),
      contains('already checkpointed'),
    );
  });

  test('a restore that went through says so, and how to undo it', () {
    final done = restoreOutcomeMessage(
      RestoreOutcome(
        restored: checkpoint(1),
        safetyCheckpoint: checkpoint(4),
        files: const [file],
        alreadyThere: false,
      ),
    );
    expect(done, startsWith('Restored 1 file.'));
    expect(done, contains('Undo it by restoring checkpoint 4.'));
    expect(done, contains(kRestoreLeavesTheConversation));
    expect(
      restoreOutcomeMessage(
        RestoreOutcome(
          restored: checkpoint(1),
          safetyCheckpoint: null,
          files: const [],
          alreadyThere: true,
        ),
      ),
      'The working tree already matched that checkpoint. Nothing changed.',
    );
  });

  Map<String, Object?> wire(CheckpointRestoreAnswer answer) =>
      (jsonDecode(jsonEncode(answer.toJson())) as Map).cast();

  test('an answer carries the outcome whole', () {
    final back = CheckpointRestoreAnswer.fromJson(
      wire(
        CheckpointRestoreAnswer.restored(
          RestoreOutcome(
            restored: checkpoint(1),
            safetyCheckpoint: checkpoint(2),
            files: const [file],
            alreadyThere: false,
          ),
        ),
      ),
    );
    expect(back.conflict, isNull);
    final outcome = back.outcomeOrThrow;
    expect(outcome.restored.id, 'c1');
    expect(outcome.safetyCheckpoint?.sequence, 2);
    expect(outcome.files.single.path, 'lib/a.dart');
    expect(outcome.files.single.type, FileChangeType.modified);
    expect(outcome.alreadyThere, isFalse);
  });

  test('a conflict travels in its own words and is thrown as it was', () {
    final words = checkpointRestoreRefusal(
      treeMovedSinceLastCheckpoint: true,
      safetySequence: 3,
    )!;
    final back = CheckpointRestoreAnswer.fromJson(
      wire(
        CheckpointRestoreAnswer.refused(
          CheckpointConflict(words, safetyCheckpoint: checkpoint(3)),
        ),
      ),
    );
    expect(back.outcome, isNull);
    expect(
      () => back.outcomeOrThrow,
      throwsA(
        isA<CheckpointConflict>()
            .having((c) => c.message, 'message', words)
            .having((c) => c.safetyCheckpoint?.id, 'safety', 'c3'),
      ),
    );
  });

  test('an answer out of shape is a FormatException', () {
    expect(
      () => CheckpointRestoreAnswer.fromJson({'restored': 3}),
      throwsFormatException,
    );
  });
}
