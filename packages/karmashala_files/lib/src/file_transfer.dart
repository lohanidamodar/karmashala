/// Moving a file from one machine to another, at the server. The three shapes
/// a copy can take are here and nowhere else, so a client only ever says
/// "copy this there" (`files.copy`).
library;

import 'dart:io';

import 'package:agent_cli/process.dart';

import 'file_space.dart';
import 'file_values.dart' show nameRefusal;

/// How far a transfer has got. [total] is null while the size is unknown — a
/// host does not always say, and a made-up total is worse than none.
class FileTransferProgress {
  const FileTransferProgress({
    required this.name,
    required this.bytes,
    this.total,
  });

  final String name;
  final int bytes;
  final int? total;

  /// 0…1, or null when there is no total to be a fraction of.
  double? get fraction =>
      total == null || total! <= 0 ? null : (bytes / total!).clamp(0, 1);
}

/// Copies one file between two [FileSpace]s.
class FileTransfer {
  const FileTransfer();

  /// Copies [source] out of [from] into the directory [destination] of [to],
  /// keeping its name. Answers where it landed.
  ///
  /// Three shapes, decided by [FileSpace.hostPathOf]: both sides reachable
  /// with `dart:io` (a copy), one side remote (an SFTP read or write), or both
  /// remote (down to a temporary file and back up, because the two hosts have
  /// no link to each other).
  Future<EnvironmentPath> copy({
    required FileSpace from,
    required EnvironmentPath source,
    required FileSpace to,
    required EnvironmentPath destination,
    String? name,
    void Function(FileTransferProgress progress)? onProgress,
    int? totalBytes,
  }) async {
    final leaf = name ?? from.pathContext.basename(source.path);
    final refusal = nameRefusal(leaf);
    if (refusal != null) throw FileSpaceException(refusal);
    final target = to.child(destination, leaf);
    void report(int bytes) => onProgress?.call(
      FileTransferProgress(name: leaf, bytes: bytes, total: totalBytes),
    );

    final here = to.hostPathOf(target);
    if (here != null) {
      // The destination is a file this process can write: whichever side the
      // bytes come from, they are read straight into it.
      await from.copyToLocal(source, here, onProgress: report);
      return target;
    }
    final there = from.hostPathOf(source);
    if (there != null) {
      await to.copyFromLocal(there, target, onProgress: report);
      return target;
    }
    // Host to host. Nothing here can ask one to send to the other, so the file
    // comes down and goes back up, and the temporary copy is deleted whatever
    // happens to the second leg.
    final staging = await Directory.systemTemp.createTemp('ks-transfer-');
    final staged = '${staging.path}${Platform.pathSeparator}$leaf';
    try {
      await from.copyToLocal(source, staged, onProgress: report);
      await to.copyFromLocal(staged, target, onProgress: report);
    } finally {
      try {
        await staging.delete(recursive: true);
      } on FileSystemException {
        // A temporary file left behind costs nothing; failing the transfer
        // over it would cost the user the copy they just watched succeed.
      }
    }
    return target;
  }
}
