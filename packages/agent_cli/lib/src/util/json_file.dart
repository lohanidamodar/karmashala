import 'dart:convert';
import 'dart:io';

/// One read of a JSON-object file, with the reason there is no object when
/// there is none: an absent credentials file is "signed out", a corrupt or
/// unreadable one is not, and the two used to arrive as the same null.
sealed class JsonFileRead {
  const JsonFileRead(this.path);
  final String path;

  /// The object, or null for every other outcome.
  Map<String, dynamic>? get object => null;

  /// Why there is no object — null when there is one, and when the file is
  /// simply absent, which is the one emptiness that needs no explaining.
  String? get failure => null;
}

class JsonFileAbsent extends JsonFileRead {
  const JsonFileAbsent(super.path);
}

class JsonFileUnreadable extends JsonFileRead {
  const JsonFileUnreadable(super.path, this.cause);
  final FileSystemException cause;

  @override
  String get failure =>
      'Could not read $path (${cause.osError?.message ?? cause.message}).';
}

class JsonFileMalformed extends JsonFileRead {
  const JsonFileMalformed(super.path, this.cause);
  final FormatException cause;

  @override
  String get failure => '$path is not valid JSON (${cause.message}).';
}

class JsonFileNotAnObject extends JsonFileRead {
  const JsonFileNotAnObject(super.path);

  @override
  String get failure => '$path does not contain a JSON object.';
}

class JsonObjectFound extends JsonFileRead {
  const JsonObjectFound(super.path, this.object);

  @override
  final Map<String, dynamic> object;
}

/// Reads [path] as a JSON object and says which of the five things happened.
Future<JsonFileRead> readJsonObjectFile(String path) async {
  final String raw;
  try {
    // Not File.exists: that is false for a directory, which is not "absent".
    if (await FileSystemEntity.type(path) == FileSystemEntityType.notFound) {
      return JsonFileAbsent(path);
    }
    raw = await File(path).readAsString();
  } on FileSystemException catch (e) {
    return JsonFileUnreadable(path, e);
  }
  return jsonObjectReadOf(path, raw);
}

/// [raw], the text of the file at [path], as one of the outcomes a read has
/// once the file has been read — wherever it was read from.
JsonFileRead jsonObjectReadOf(String path, String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException catch (e) {
    return JsonFileMalformed(path, e);
  }
  if (decoded is! Map<String, dynamic>) return JsonFileNotAnObject(path);
  return JsonObjectFound(path, decoded);
}
