import 'package:karmashala_git/git.dart';

import '../domain/checkpoint.dart';
import '../domain/checkpoint_json.dart';
import 'checkpoint_service.dart';

/// What a restore asked of the server came to: done ([outcome]), or refused
/// because the tree moved ([conflict]) — the one refusal a client asks the
/// person about and then repeats with `confirm`.
final class CheckpointRestoreAnswer {
  const CheckpointRestoreAnswer.restored(RestoreOutcome this.outcome)
    : conflict = null;

  const CheckpointRestoreAnswer.refused(CheckpointConflict this.conflict)
    : outcome = null;

  final RestoreOutcome? outcome;
  final CheckpointConflict? conflict;

  /// The outcome, or the conflict thrown exactly as [CheckpointService.restore]
  /// throws it, so a client's code reads as it did over the service.
  RestoreOutcome get outcomeOrThrow => outcome ?? (throw conflict!);

  Map<String, Object?> toJson() => switch ((outcome, conflict)) {
    (final RestoreOutcome o, _) => {
      'restored': checkpointToJson(o.restored),
      'safetyCheckpoint': ?_checkpoint(o.safetyCheckpoint),
      'alreadyThere': o.alreadyThere,
      'files': [
        for (final file in o.files) {'path': file.path, 'type': file.type.name},
      ],
    },
    (_, final CheckpointConflict c) => {
      'conflict': {
        'message': c.message,
        'safetyCheckpoint': ?_checkpoint(c.safetyCheckpoint),
      },
    },
    _ => const {},
  };

  /// Throws [FormatException] on an answer out of shape.
  static CheckpointRestoreAnswer fromJson(Map<String, Object?> json) {
    try {
      final conflict = json['conflict'];
      if (conflict is Map) {
        return CheckpointRestoreAnswer.refused(
          CheckpointConflict(
            conflict['message']! as String,
            safetyCheckpoint: _optional(conflict['safetyCheckpoint']),
          ),
        );
      }
      return CheckpointRestoreAnswer.restored(
        RestoreOutcome(
          restored: checkpointFromJson(
            (json['restored']! as Map).cast<String, Object?>(),
          ),
          safetyCheckpoint: _optional(json['safetyCheckpoint']),
          alreadyThere: json['alreadyThere']! as bool,
          files: [
            for (final file in (json['files']! as List).cast<Map>())
              FileChange(
                path: file['path']! as String,
                type: FileChangeType.values.firstWhere(
                  (t) => t.name == file['type'],
                  orElse: () => FileChangeType.unknown,
                ),
                staged: false,
                unstaged: true,
              ),
          ],
        ),
      );
    } on TypeError {
      throw const FormatException('not a restore answer');
    }
  }

  static Map<String, Object?>? _checkpoint(Checkpoint? c) =>
      c == null ? null : checkpointToJson(c);

  static Checkpoint? _optional(Object? json) =>
      json is Map ? checkpointFromJson(json.cast<String, Object?>()) : null;
}
