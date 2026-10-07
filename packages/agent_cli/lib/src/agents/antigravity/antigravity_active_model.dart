import 'package:path/path.dart' as p;

import '../../util/sqlite_rows.dart';
import '../adapter/agent_active_model.dart';

/// The model an Antigravity conversation was set to run, from its own
/// `conversations/<id>.db`: the newest `gen_metadata` row naming it, at
/// protobuf field 3 → 28 (`gemini-3.8-flash-high`; field 1 → 19 is the base
/// model, `gemini-3.8-flash`). Read off 6 of 55 WSL conversations, 2026-10-07; the
/// schema is unpublished, so nothing else in a row is trusted. Its JSONL
/// transcript names none, and the Windows install's `.pb` nothing readable.
class AntigravityActiveModel
    implements AgentActiveModel, AgentStoreActiveModel {
  const AntigravityActiveModel();

  /// The rows looked through, newest first: one conversation of 144 rows
  /// named it only in its last.
  static const int _rows = 8;

  @override
  ActiveModelReading? latestIn(Iterable<String> lines) => null;

  @override
  Future<ActiveModelReading?> latestInStore(
    String recordPath,
    SqliteRowReader readRows,
  ) async {
    if (p.extension(recordPath) != '.db') return null;
    final rows = await readRows(
      recordPath,
      'SELECT data FROM gen_metadata ORDER BY idx DESC LIMIT $_rows',
    );
    for (final row in rows ?? const <Map<String, Object?>>[]) {
      final data = row['data'];
      if (data is! List<int>) continue;
      final model = _stringAt(data, const [3, 28]);
      if (model != null && model.isNotEmpty) return ActiveModelReading(model);
    }
    return null;
  }
}

/// The string at [path] — length-delimited fields, outermost first — in a
/// protobuf message, or null when it is not there or the bytes are not one.
String? _stringAt(List<int> bytes, List<int> path) {
  var start = 0;
  var end = bytes.length;
  for (final wanted in path) {
    final found = _field(bytes, start, end, wanted);
    if (found == null) return null;
    (start, end) = found;
  }
  return String.fromCharCodes(bytes, start, end);
}

/// The bounds of the first length-delimited [field] between [start] and
/// [end], or null.
(int, int)? _field(List<int> bytes, int start, int end, int field) {
  var i = start;
  int? varint() {
    var value = 0;
    for (var shift = 0; shift < 64 && i < end; shift += 7) {
      final byte = bytes[i++];
      value |= (byte & 0x7f) << shift;
      if (byte < 0x80) return value;
    }
    return null;
  }

  while (i < end) {
    final key = varint();
    if (key == null) return null;
    switch (key & 7) {
      case 0:
        if (varint() == null) return null;
      case 1:
        i += 8;
      case 5:
        i += 4;
      case 2:
        final length = varint();
        if (length == null || i + length > end) return null;
        if (key >> 3 == field) return (i, i + length);
        i += length;
      default:
        return null;
    }
  }
  return null;
}
