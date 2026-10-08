import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_mcp/access.dart'
    show HandshakePermissions, SystemHandshakePermissions;
import 'package:path/path.dart' as p;

/// One JSON file in the server's owner-only `secrets` folder, written the
/// way the env vault writes its own: folder and a temp file restricted before
/// anything goes in, then renamed over. A file that will not parse is left
/// alone and refuses writes.
class OwnerOnlyJsonFile {
  OwnerOnlyJsonFile({
    required String dataDirectory,
    required this.fileName,
    required this.what,
    this.permissions = const SystemHandshakePermissions(),
  }) : _directory = Directory(p.join(dataDirectory, directoryName));

  static const String directoryName = 'secrets';

  final String fileName;

  /// What the file holds, for a refusal: "the GitHub token store".
  final String what;
  final HandshakePermissions permissions;
  final Directory _directory;

  /// Why the file could not be read, while it could not.
  String? unreadable;

  Future<void> _writes = Future<void>.value();

  File get _file => File(p.join(_directory.path, fileName));

  /// The file's object, or an empty one when there is no file.
  Map<String, Object?> read() {
    final file = _file;
    if (!file.existsSync()) return const {};
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map) return decoded.cast<String, Object?>();
      unreadable = 'not an object';
    } on Object catch (error) {
      // The type only: a parse error can quote the file.
      unreadable = '${error.runtimeType}';
    }
    return const {};
  }

  /// Writes [snapshot] after any write already in flight.
  Future<void> write(Map<String, Object?> snapshot) {
    final problem = unreadable;
    if (problem != null) {
      return Future.error(
        DataRefused(
          DataRefusalCode.failed,
          '$what could not be read ($problem), so nothing is written over it',
        ),
      );
    }
    final done = _writes.then((_) => _write(snapshot));
    _writes = done.catchError((Object _) {});
    return done;
  }

  Future<void> _write(Map<String, Object?> snapshot) async {
    try {
      if (!_directory.existsSync()) _directory.createSync(recursive: true);
      if (!await permissions.restrictDirectory(_directory)) {
        throw DataRefused(
          DataRefusalCode.failed,
          '$what\'s folder could not be made owner-only, so nothing was '
          'written',
        );
      }
      final temp = File('${_file.path}.tmp');
      await temp.writeAsString('');
      if (!await permissions.restrictFile(temp)) {
        await temp.delete();
        throw DataRefused(
          DataRefusalCode.failed,
          '$what\'s file could not be made owner-only, so nothing was written',
        );
      }
      await temp.writeAsString(jsonEncode(snapshot), flush: true);
      await temp.rename(_file.path);
    } on DataRefused {
      rethrow;
    } on FileSystemException catch (error) {
      throw DataRefused(
        DataRefusalCode.failed,
        '$what could not be written: ${error.message}',
      );
    }
  }
}
