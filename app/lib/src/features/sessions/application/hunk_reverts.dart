import 'dart:convert';

import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:karmashala_files/values.dart' show FileStamp, WriteExpectation;
import 'package:riverpod/riverpod.dart';

import '../../checkpoints/data/checkpoints_data.dart';
import '../../files/data/files_client.dart';
import '../../git/data/git_data.dart';
import 'diff_hunks.dart';

export 'package:agent_cli/process.dart' show EnvironmentPath;
export 'diff_hunks.dart';

/// A file's text as it was read, and the stamp a write must still find.
typedef ReadText = ({String text, FileStamp? stamp});

/// The file operations a revert needs, done by the server wherever the file
/// is — this machine, WSL or an SSH host. Never this process's own disk.
abstract interface class HunkFiles {
  /// Null when nothing is at [path].
  Future<ReadText?> read(EnvironmentPath path);

  /// Throws [FilesStaleException] when the file is no longer [stamp].
  Future<void> write(EnvironmentPath path, String text, FileStamp? stamp);
}

/// [HunkFiles] through the server's files ops.
class ServerHunkFiles implements HunkFiles {
  const ServerHunkFiles(this._files);

  final FilesClient _files;

  @override
  Future<ReadText?> read(EnvironmentPath path) async {
    final stat = await _files.stat(path);
    if (!stat.exists || stat.isDirectory) return null;
    final bytes = await _files.read(path);
    return (text: utf8.decode(bytes), stamp: stat.stamp);
  }

  @override
  Future<void> write(EnvironmentPath path, String text, FileStamp? stamp) =>
      _files.write(
        path,
        utf8.encode(text),
        expect: stamp == null
            ? const WriteExpectation.any()
            : WriteExpectation.version(stamp),
      );
}

/// How a revert ended.
sealed class RevertOutcome {
  const RevertOutcome();
}

/// Put back, after a checkpoint of the file as it was.
final class Reverted extends RevertOutcome {
  const Reverted();
}

/// The change no longer applies: the file moved on. Nothing was written.
final class RevertConflict extends RevertOutcome {
  const RevertConflict(this.reason);
  final String reason;
}

/// Something refused — no checkpoint, an unreadable file. Nothing written.
final class RevertFailed extends RevertOutcome {
  const RevertFailed(this.reason);
  final String reason;
}

/// **Keep or revert an agent's change, a hunk at a time.** The reverse is
/// worked out here from the file the server reads; a checkpoint of the
/// session's trees is taken first, so a revert is undone from Checkpoints;
/// then the server writes it, refusing if the file moved meanwhile.
class HunkReverts {
  HunkReverts({
    required this.files,
    required this.checkpoint,
    required this.discard,
  });

  final HunkFiles files;

  /// Takes a checkpoint of [sessionId]'s trees, labelled [label].
  final Future<void> Function(String sessionId, String label) checkpoint;

  /// Puts tracked [path] in [checkout] back to what git has: the Files tab's
  /// Revert file, whose diff is the working tree's against git.
  final Future<void> Function(EnvironmentPath checkout, String path) discard;

  /// Puts [hunks] of [file] back, all or none.
  Future<RevertOutcome> revert({
    required String sessionId,
    required EnvironmentPath file,
    required List<EditHunk> hunks,
  }) async {
    final ReadText? read;
    try {
      read = await files.read(file);
    } on FormatException {
      return const RevertFailed('The file is not text, so it was left alone.');
    } on FilesException catch (error) {
      return RevertFailed(error.message);
    }
    if (read == null) {
      return const RevertConflict(
        'The file is not there any more: it was moved or deleted since that '
        'turn.',
      );
    }
    final String text;
    switch (revertHunks(read.text, hunks)) {
      case HunkReverted(text: final put):
        text = put;
      case HunkConflict(:final reason):
        return RevertConflict(reason);
    }
    final name = _nameOf(file.path);
    final failed = await _checkpointFirst(
      sessionId,
      hunks.length == 1
          ? 'Before reverting a change in $name'
          : 'Before reverting $name',
    );
    if (failed != null) return failed;
    try {
      await files.write(file, text, read.stamp);
    } on FilesStaleException {
      return const RevertConflict(
        'The file changed while it was being put back, so nothing was '
        'written.',
      );
    } on FilesException catch (error) {
      return RevertFailed(error.message);
    }
    return const Reverted();
  }

  /// The Files tab's Revert file: [path] in [checkout] back to git's.
  Future<RevertOutcome> revertToGit({
    required String sessionId,
    required EnvironmentPath checkout,
    required String path,
  }) async {
    final failed = await _checkpointFirst(
      sessionId,
      'Before reverting ${_nameOf(path)}',
    );
    if (failed != null) return failed;
    try {
      await discard(checkout, path);
    } on Object catch (error) {
      return RevertFailed(error is StateError ? error.message : '$error');
    }
    return const Reverted();
  }

  Future<RevertFailed?> _checkpointFirst(String sessionId, String label) async {
    try {
      await checkpoint(sessionId, label);
      return null;
    } on Object catch (error) {
      return RevertFailed(
        'No checkpoint could be taken first, so nothing was changed: '
        '${error is StateError ? error.message : error}',
      );
    }
  }

  static String _nameOf(String path) =>
      path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).lastOrNull ??
      path;
}

final hunkRevertsProvider = Provider<HunkReverts>(
  (ref) => HunkReverts(
    files: ServerHunkFiles(ref.watch(filesClientProvider)),
    checkpoint: (sessionId, label) async {
      await ref
          .read(checkpointsDataProvider)
          .captureNow(sessionId, label: label);
    },
    discard: (checkout, path) =>
        ref.read(gitDataProvider).discard(checkout, tracked: [path]),
  ),
);
