import 'package:agent_cli/process.dart';
import 'package:karmashala_git/git.dart';

/// Why a checkpoint was taken. It is not decoration: [safety] checkpoints are
/// what make a restore undoable, so a reader needs to be able to tell them from
/// the turns they were taken to protect.
enum CheckpointReason {
  /// An agent session finished a turn.
  turn,

  /// Taken immediately before a restore, so the restore can itself be undone.
  safety,

  /// The user (or an agent, through MCP) asked for one.
  manual;

  static CheckpointReason fromName(String name) => values.firstWhere(
    (r) => r.name == name,
    orElse: () => CheckpointReason.manual,
  );
}

/// What a repository's working tree looked like at one moment, and what had
/// changed since the moment before.
///
/// The content lives in git — [treeSha] is a real tree object and [commitSha]
/// the commit that anchors it — so a checkpoint is small, and restoring one is
/// a diff and a patch rather than a copy.
class Checkpoint {
  const Checkpoint({
    required this.id,
    required this.sessionId,
    required this.repository,
    required this.sequence,
    required this.treeSha,
    required this.commitSha,
    required this.parentCommitSha,
    required this.headSha,
    required this.reason,
    required this.createdAt,
    this.label,
    this.files = const [],
  });

  final String id;

  /// The session whose turn produced this. Checkpoints are attached by id
  /// rather than by object reference so the sessions feature owns its own
  /// records and this one owns its own table.
  final String sessionId;

  /// The working tree this describes — a repository, or the worktree a session
  /// was given.
  final EnvironmentPath repository;

  /// 1-based position in this session's chain.
  final int sequence;

  final String treeSha;
  final String commitSha;

  /// The previous checkpoint's commit, or `null` for the first one.
  final String? parentCommitSha;

  /// Where the repository's own `HEAD` was, so a reader can tell a checkpoint
  /// taken before a commit from one taken after. `null` in a repository with no
  /// commits yet.
  final String? headSha;

  final CheckpointReason reason;
  final DateTime createdAt;

  /// A human label, for a manual checkpoint or a restore.
  final String? label;

  /// What changed between the previous checkpoint and this one.
  final List<FileChange> files;

  Checkpoint copyWith({List<FileChange>? files}) => Checkpoint(
    id: id,
    sessionId: sessionId,
    repository: repository,
    sequence: sequence,
    treeSha: treeSha,
    commitSha: commitSha,
    parentCommitSha: parentCommitSha,
    headSha: headSha,
    reason: reason,
    createdAt: createdAt,
    label: label,
    files: files ?? this.files,
  );

  /// The ref that keeps this session's checkpoint chain reachable.
  ///
  /// One ref per session, not per checkpoint: the commits form a chain, so
  /// holding the tip holds all of them, and `git gc` walks the rest.
  static String refFor(String sessionId) =>
      'refs/karmashala/checkpoints/$sessionId';
}
