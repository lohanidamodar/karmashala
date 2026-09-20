/// Pulling **what an agent wrote to a file** out of the record it keeps of its
/// own run.
///
/// Claude Code records the call on the `assistant` line and the result, with a
/// `structuredPatch`, on the `user` line after it; **a created file's
/// `structuredPatch` is empty**, so trusting the patch alone shows a new file as
/// "nothing changed". Codex writes one `patch_apply_end` per applied patch, and
/// nothing here reads a file from disk.
library;

import 'package:agent_cli/descriptors.dart';
import '../domain/file_edit.dart';

/// Claude Code's file-writing tools. `NotebookEdit` is deliberately absent: its
/// input addresses a cell, not a line range, and rendering it as a text diff
/// would be a guess.
const Set<String> kClaudeFileEditTools = {'Edit', 'Write', 'MultiEdit'};

/// Every file edit recorded on one decoded transcript line, read by [cli]'s
/// rules.
List<FileEditRecord> fileEditsFromTranscriptLine(
  Map<String, Object?> json,
  String cli,
) => cli == AgentIds.codex ? codexFileEdits(json) : claudeFileEdits(json);

/// Every file edit on one line of a Claude Code (or Antigravity) transcript.
List<FileEditRecord> claudeFileEdits(Map<String, Object?> json) {
  // The result is the better record — it knows what the write actually did —
  // so it wins whenever the line carries one.
  final result = json['toolUseResult'];
  if (result is Map) {
    final fromResult = _claudeResultEdit(result);
    if (fromResult != null) return [fromResult];
  }
  if (json['type'] != 'assistant') return const [];
  final content = (json['message'] as Map?)?['content'];
  if (content is! List) return const [];

  final edits = <FileEditRecord>[];
  for (final block in content) {
    if (block is! Map) continue;
    if (block['type'] != 'tool_use') continue;
    final name = block['name'];
    if (name is! String || !kClaudeFileEditTools.contains(name)) continue;
    edits.addAll(claudeToolInputEdits(name, block['input']));
  }
  return edits;
}

/// The edits described by a Claude tool call's raw `input`.
///
/// The engine's own `tool.call` event carries exactly this map: a session hosted
/// by the engine has the input but never a result, and an in-flight write must
/// still be showable.
List<FileEditRecord> claudeToolInputEdits(String name, Object? input) {
  if (input is! Map) return const [];
  final path = input['file_path'];
  if (path is! String || path.isEmpty) return const [];

  switch (name) {
    case 'Write':
      final content = input['content'];
      if (content is! String) return const [];
      // `modified`, not `created`: a Write overwrites as readily as it creates,
      // and the call alone cannot tell which. The result line upgrades it.
      return [
        FileEditRecord(
          path: path,
          kind: FileEditKind.modified,
          toolName: name,
          newText: content,
        ),
      ];
    case 'Edit':
      return [
        FileEditRecord(
          path: path,
          kind: FileEditKind.modified,
          toolName: name,
          oldText: _string(input['old_string']),
          newText: _string(input['new_string']),
        ),
      ];
    case 'MultiEdit':
      final edits = input['edits'];
      if (edits is! List) return const [];
      return [
        for (final edit in edits)
          if (edit is Map)
            FileEditRecord(
              path: path,
              kind: FileEditKind.modified,
              toolName: name,
              oldText: _string(edit['old_string']),
              newText: _string(edit['new_string']),
            ),
      ];
    default:
      return const [];
  }
}

/// The edits described by a normalized `tool.call` event payload.
List<FileEditRecord> fileEditsFromToolCall({
  required String name,
  required Object? input,
}) => kClaudeFileEditTools.contains(name)
    ? claudeToolInputEdits(name, input)
    : const [];

/// Every file edit on one line of a Codex rollout.
List<FileEditRecord> codexFileEdits(Map<String, Object?> json) {
  final payload = json['payload'];
  if (payload is! Map) return const [];
  if (payload['type'] != 'patch_apply_end') return const [];
  // A patch that failed left the files alone; reporting it would show the user
  // a change that is not in their tree.
  if (payload['success'] == false) return const [];
  final changes = payload['changes'];
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

/// Every file edit in a transcript read line by line, with each tool call
/// **collapsed onto its own result**.
///
/// Claude records one write twice — the call on an `assistant` line, the result
/// on the `user` line after it — so [add] replaces the call with the result in
/// place, keeping the position the call had in the conversation.
class FileEditCollector {
  final List<FileEditRecord> _edits = [];

  /// Where in [_edits] the call with a given `tool_use` id landed.
  final Map<String, int> _byToolUseId = {};

  /// The edits so far, oldest first.
  List<FileEditRecord> get edits => List.unmodifiable(_edits);

  /// Reads one decoded transcript line.
  void add(Map<String, Object?> json, String cli) {
    if (cli == AgentIds.codex) {
      _edits.addAll(codexFileEdits(json));
      return;
    }

    final result = json['toolUseResult'];
    if (result is Map) {
      final edit = _claudeResultEdit(result);
      if (edit == null) return;
      final at = _byToolUseId[_claudeResultId(json) ?? ''];
      // A MultiEdit call left several rows behind and its result describes one
      // file, so an id recorded more than once is left alone.
      if (at != null && at < _edits.length && _edits[at].path == edit.path) {
        _edits[at] = edit;
      } else {
        _edits.add(edit);
      }
      return;
    }

    if (json['type'] != 'assistant') return;
    final content = (json['message'] as Map?)?['content'];
    if (content is! List) return;
    for (final block in content) {
      if (block is! Map || block['type'] != 'tool_use') continue;
      final name = block['name'];
      if (name is! String || !kClaudeFileEditTools.contains(name)) continue;
      final found = claudeToolInputEdits(name, block['input']);
      final id = block['id'];
      if (id is String && found.length == 1) _byToolUseId[id] = _edits.length;
      _edits.addAll(found);
    }
  }
}

/// One edit out of a Claude `toolUseResult`, or null when the result is not a
/// file write (a Bash result, a Read, …).
FileEditRecord? _claudeResultEdit(Map<Object?, Object?> result) {
  final path = result['filePath'];
  if (path is! String || path.isEmpty) return null;

  final patch = _unifiedFromStructuredPatch(result['structuredPatch']);
  // `type: create` is the only place the record says a file is new; an Edit
  // carries no `type` at all, and a Write to an existing file says `update`.
  final kind = result['type'] == 'create'
      ? FileEditKind.created
      : FileEditKind.modified;

  if (patch != null) {
    // The whole `originalFile` is deliberately dropped here: with a patch in
    // hand nothing needs it, and it is the largest string in the record.
    return FileEditRecord(
      path: path,
      kind: kind,
      toolName: result['oldString'] != null ? 'Edit' : 'Write',
      recordedDiff: patch,
    );
  }

  final oldText =
      _string(result['originalFile']) ?? _string(result['oldString']);
  final newText = _string(result['content']) ?? _string(result['newString']);
  if (oldText == null && newText == null) return null;
  return FileEditRecord(
    path: path,
    kind: kind,
    toolName: result['content'] != null ? 'Write' : 'Edit',
    oldText: oldText,
    newText: newText,
  );
}

/// The `tool_use_id` a `toolUseResult` line is answering.
String? _claudeResultId(Map<String, Object?> json) {
  final content = (json['message'] as Map?)?['content'];
  if (content is! List) return null;
  for (final block in content) {
    if (block is Map && block['type'] == 'tool_result') {
      final id = block['tool_use_id'];
      if (id is String) return id;
    }
  }
  return null;
}

/// Claude's `structuredPatch` as unified-diff text, or null when there is none.
///
/// An **empty** list is "no patch", not "an empty patch": that is exactly what
/// a created file records, and its content is the diff.
String? _unifiedFromStructuredPatch(Object? patch) {
  if (patch is! List || patch.isEmpty) return null;
  final out = <String>[];
  for (final hunk in patch) {
    if (hunk is! Map) continue;
    final lines = hunk['lines'];
    if (lines is! List) continue;
    out.add(
      '@@ -${hunk['oldStart']},${hunk['oldLines']} '
      '+${hunk['newStart']},${hunk['newLines']} @@',
    );
    for (final line in lines) {
      if (line is String) out.add(line);
    }
  }
  return out.isEmpty ? null : out.join('\n');
}

/// A JSON value as a non-empty String, or null. JSON `null` and a value of the
/// wrong type are the same answer: the record does not have this.
String? _string(Object? value) =>
    value is String && value.isNotEmpty ? value : null;
