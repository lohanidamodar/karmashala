/// Pulling **what Codex wrote to a file** out of its rollout: one
/// `patch_apply_end` per applied patch. Nothing here reads a file from disk.
library;

import '../domain/file_edit.dart';

/// Every file edit on one line of a Codex rollout.
List<FileEditRecord> codexFileEdits(Map<String, Object?> json) {
  final payload = json['payload'];
  if (payload is! Map) return const [];
  if (payload['type'] != 'patch_apply_end') return const [];
  // A patch that failed left the files alone; reporting it would show the user
  // a change that is not in their tree.
  if (payload['success'] == false) return const [];
  return codexChangeEdits(payload['changes']);
}

/// The edits a Codex `changes` map (path to `add`/`delete`/`update`) makes,
/// as `patch_apply_end` and a completed `FileChange` item both carry it.
List<FileEditRecord> codexChangeEdits(Object? changes) {
  if (changes is! Map) return const [];
  final edits = <FileEditRecord>[];
  changes.forEach((path, change) {
    if (path is! String || change is! Map) return;
    switch (change['type']) {
      case 'add':
        edits.add(
          FileEditRecord(
            path: path,
            kind: FileEditKind.created,
            toolName: 'apply_patch',
            newText: _string(change['content']),
          ),
        );
      case 'delete':
        edits.add(
          FileEditRecord(
            path: path,
            kind: FileEditKind.deleted,
            toolName: 'apply_patch',
            oldText: _string(change['content']),
          ),
        );
      case 'update':
        edits.add(
          FileEditRecord(
            path: path,
            kind: FileEditKind.modified,
            toolName: 'apply_patch',
            recordedDiff: _string(change['unified_diff']),
            renamedTo: _string(change['move_path']),
          ),
        );
    }
  });
  return edits;
}

/// A JSON value as a non-empty String, or null.
String? _string(Object? value) =>
    value is String && value.isNotEmpty ? value : null;
