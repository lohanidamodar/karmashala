import 'dart:io';

import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:agent_cli/read.dart' show kMaxSessionMediaBytes;
import 'package:path/path.dart' as p;

import '../../files/data/files_client.dart';

/// Why a picture could not be brought here, in a sentence meant to be shown.
class MediaUnavailable implements Exception {
  const MediaUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// **Pictures a server elsewhere holds, brought here once** (Stage 0 step
/// 10): through `files.read`, into [cache] under a name made of the file's
/// path, size and time, so an unchanged picture is never fetched twice and
/// a changed one is. Two askers of one picture share one download.
class ServerMediaFiles {
  ServerMediaFiles(
    this._files,
    this._cache, {
    this.maxBytes = kMaxSessionMediaBytes,
    this.keptFiles = 300,
  });

  final FilesClient _files;
  final Future<Directory> Function() _cache;
  final int maxBytes;

  /// How many downloads the cache keeps; the least recently written go first.
  final int keptFiles;

  final _running = <String, Future<File>>{};

  /// [path] as a file on this machine. Throws [MediaUnavailable].
  Future<File> fetch(EnvironmentPath path) {
    final key = pathKey(path);
    return _running[key] ??= _fetch(
      path,
    ).whenComplete(() => _running.remove(key));
  }

  Future<File> _fetch(EnvironmentPath path) async {
    try {
      // The server's disk is this one's: the file it names opens as it is.
      final local = await _files.localPathOf(path);
      if (local != null) return File(local);
      final stat = await _files.stat(path);
      if (!stat.exists) {
        throw const MediaUnavailable('That image is no longer on disk.');
      }
      if (stat.isDirectory) {
        throw const MediaUnavailable('That file is not an image.');
      }
      if (stat.size > maxBytes) {
        throw MediaUnavailable(
          'That image is too large to preview here '
          '(${(stat.size / (1024 * 1024)).toStringAsFixed(1)} MB).',
        );
      }
      final folder = await _cache();
      final extension = pathContextOf(path.path).extension(path.path);
      final name =
          '${_hash('${pathKey(path)}|${stat.size}|'
          '${stat.stamp?.modified?.toUtc().toIso8601String()}')}'
          '$extension';
      final file = File(p.join(folder.path, name));
      if (await file.exists() && await file.length() == stat.size) {
        return file;
      }
      final bytes = await _files.read(path, length: stat.size);
      final partial = File('${file.path}.part');
      await partial.writeAsBytes(bytes, flush: true);
      await partial.rename(file.path);
      await _trim(folder);
      return file;
    } on MediaUnavailable {
      rethrow;
    } on FilesException catch (error) {
      throw MediaUnavailable('That image could not be brought here: $error');
    } on FileSystemException catch (error) {
      throw MediaUnavailable(
        'That image could not be kept here: '
        '${error.osError?.message ?? error.message}',
      );
    }
  }

  Future<void> _trim(Directory folder) async {
    final files = <(File, DateTime)>[];
    await for (final entry in folder.list()) {
      if (entry is File) files.add((entry, (await entry.stat()).modified));
    }
    if (files.length <= keptFiles) return;
    files.sort((a, b) => a.$2.compareTo(b.$2));
    for (final (file, _) in files.take(files.length - keptFiles)) {
      try {
        await file.delete();
      } on FileSystemException {
        // One on screen may be held open; the next trim takes it.
      }
    }
  }

  /// FNV-1a, for a file name; not a secret.
  static String _hash(String value) {
    var hash = 0xcbf29ce484222325;
    for (final unit in value.codeUnits) {
      hash = (hash ^ unit) * 0x100000001b3;
      hash &= 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}
