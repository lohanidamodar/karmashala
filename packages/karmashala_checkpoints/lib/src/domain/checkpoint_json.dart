import 'package:agent_cli/process.dart';
import 'package:karmashala_git/git.dart';

import 'checkpoint.dart';

/// A checkpoint's wire shape: its metadata only — the content is git's.
Map<String, Object?> checkpointToJson(Checkpoint c) => {
  'id': c.id,
  'sessionId': c.sessionId,
  'repository': {
    'environmentId': c.repository.environmentId,
    'path': c.repository.path,
  },
  'sequence': c.sequence,
  'treeSha': c.treeSha,
  'commitSha': c.commitSha,
  'parentCommitSha': ?c.parentCommitSha,
  'headSha': ?c.headSha,
  'reason': c.reason.name,
  'createdAt': c.createdAt.toUtc().toIso8601String(),
  'label': ?c.label,
  'turn': ?c.turn,
  'prompt': ?c.prompt,
  'files': [
    for (final file in c.files)
      {
        'path': file.path,
        'type': file.type.name,
        if (c.lineStats[file.path] case final stat?) ...{
          'added': ?stat.added,
          'removed': ?stat.removed,
          'stat': true,
        },
      },
  ],
};

/// Throws [FormatException] on a checkpoint out of shape.
Checkpoint checkpointFromJson(Map<String, Object?> json) {
  try {
    final repository = json['repository']! as Map;
    final files = (json['files'] as List? ?? const []).cast<Map>();
    return Checkpoint(
      id: json['id']! as String,
      sessionId: json['sessionId']! as String,
      repository: EnvironmentPath(
        environmentId: repository['environmentId']! as String,
        path: repository['path']! as String,
      ),
      sequence: json['sequence']! as int,
      treeSha: json['treeSha']! as String,
      commitSha: json['commitSha']! as String,
      parentCommitSha: json['parentCommitSha'] as String?,
      headSha: json['headSha'] as String?,
      reason: CheckpointReason.fromName(json['reason']! as String),
      createdAt: DateTime.parse(json['createdAt']! as String).toUtc(),
      label: json['label'] as String?,
      turn: json['turn'] as int?,
      prompt: json['prompt'] as String?,
      files: [
        for (final file in files)
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
      lineStats: {
        for (final file in files)
          if (file['stat'] == true)
            file['path']! as String: FileDiffStat(
              added: file['added'] as int?,
              removed: file['removed'] as int?,
            ),
      },
    );
  } on TypeError {
    throw const FormatException('not a checkpoint');
  }
}
