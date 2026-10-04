import 'dart:convert';

import 'package:agent_cli/stream.dart'
    show FileEditKind, FileEditRecord, boundedToolEdits;
import 'package:karmashala_acp/karmashala_acp.dart';

/// Set on a stored tool call whose diff content was cut to fit.
const String kEditsTruncatedKey = 'editsTruncated';

/// The most of a call's `rawInput`, encoded, stored whole. A `Write`'s input
/// holds the whole file, which its diff already carries.
const int kMaxStoredRawInputChars = 8 * 1024;

/// How much of each string in an over-budget `rawInput` is kept.
const int kStoredRawInputStringChars = 512;

/// [call] as its `session_messages` row stores it: `diff` content bounded the
/// way the chat bounds edits, and an oversized `rawInput` cut.
Map<String, Object?> storedToolCallJson(ToolCallUpdate call) {
  final json = call.toToolCallJson();
  final content = call.content;
  if (content != null && content.any((c) => c is ToolCallDiff)) {
    final diffs = content.whereType<ToolCallDiff>().toList();
    final (bounded, cut) = boundedToolEdits([
      for (final diff in diffs)
        FileEditRecord(
          path: diff.path,
          kind: diff.oldText == null
              ? FileEditKind.created
              : FileEditKind.modified,
          oldText: diff.oldText,
          newText: diff.newText,
        ),
    ]);
    var next = 0;
    json['content'] = [
      for (final item in content)
        if (item is! ToolCallDiff)
          item.toJson()
        else if (next < bounded.length)
          _diffJson(bounded[next++]),
    ];
    if (cut) json[kEditsTruncatedKey] = true;
  }
  final raw = json['rawInput'];
  if (raw != null && jsonEncode(raw).length > kMaxStoredRawInputChars) {
    json['rawInput'] = raw is Map
        ? {
            for (final MapEntry(:key, :value) in raw.entries)
              if (value is String)
                '$key': value.length > kStoredRawInputStringChars
                    ? value.substring(0, kStoredRawInputStringChars)
                    : value
              else if (value is num || value is bool)
                '$key': value,
          }
        : null;
    if (json['rawInput'] == null) json.remove('rawInput');
  }
  return json;
}

Map<String, Object?> _diffJson(FileEditRecord edit) => {
  'type': 'diff',
  'path': edit.path,
  'oldText': edit.oldText,
  'newText': edit.newText ?? '',
};
