/// Reading **what a Codex `apply_patch` call asks to write**, from the patch
/// text in its input. The call is on the line before its result, so a patch
/// still running is showable too. Nothing here reads a file from disk.
library;

import 'dart:convert';

import '../domain/file_edit.dart';

/// The tool whose input is a patch in Codex's own `*** Begin Patch` format.
const String kCodexPatchTool = 'apply_patch';

/// Every file one patch touches, in the order it names them. An update keeps
/// its hunks as [FileEditRecord.recordedDiff]; their `@@` lines carry context
/// rather than line numbers, which is what the patch format writes.
List<FileEditRecord> codexPatchEdits(String patch) {
  final edits = <FileEditRecord>[];
  String? path;
  FileEditKind? kind;
  String? movedTo;
  final body = <String>[];

  void close() {
    final at = path;
    final made = kind;
    if (at != null && made != null) {
      final text = body.join('\n');
      edits.add(switch (made) {
        FileEditKind.created => FileEditRecord(
          path: at,
          kind: made,
          toolName: kCodexPatchTool,
          newText: text,
        ),
        FileEditKind.deleted => FileEditRecord(
          path: at,
          kind: made,
          toolName: kCodexPatchTool,
        ),
        FileEditKind.modified => FileEditRecord(
          path: at,
          kind: made,
          toolName: kCodexPatchTool,
          recordedDiff: text.isEmpty ? null : text,
          renamedTo: movedTo,
        ),
      });
    }
    path = null;
    kind = null;
    movedTo = null;
    body.clear();
  }

  for (final line in const LineSplitter().convert(patch)) {
    if (_header(line, '*** Add File: ') case final at?) {
      close();
      (path, kind) = (at, FileEditKind.created);
    } else if (_header(line, '*** Update File: ') case final at?) {
      close();
      (path, kind) = (at, FileEditKind.modified);
    } else if (_header(line, '*** Delete File: ') case final at?) {
      close();
      (path, kind) = (at, FileEditKind.deleted);
    } else if (_header(line, '*** Move to: ') case final to?) {
      movedTo = to;
    } else if (line.startsWith('*** ')) {
      // `*** End Patch`, `*** End of File`: markers, not content.
      if (line.startsWith('*** End Patch')) close();
    } else if (kind == FileEditKind.created) {
      if (line.startsWith('+')) body.add(line.substring(1));
    } else if (kind == FileEditKind.modified) {
      body.add(line);
    }
  }
  close();
  return edits;
}

/// The patch an `apply_patch` call carries: the raw `input` of a custom tool
/// call, or `input` inside a function call's JSON `arguments`.
String? codexPatchOf(Map<dynamic, dynamic> payload) {
  final input = payload['input'];
  if (input is String) return input;
  final arguments = payload['arguments'];
  if (arguments is! String) return null;
  try {
    final decoded = jsonDecode(arguments);
    if (decoded is Map && decoded['input'] is String) {
      return decoded['input'] as String;
    }
  } on FormatException {
    return null;
  }
  return null;
}

/// The patch an older Codex ran through its shell tool: `command` is either
/// `["apply_patch", patch]` or a shell script that invokes `apply_patch` with
/// the patch in a heredoc. Null for any other command.
String? codexShellPatchOf(Map<dynamic, dynamic> payload) {
  final arguments = payload['arguments'];
  if (arguments is! String || !arguments.contains(kCodexPatchTool)) {
    return null;
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(arguments);
  } on FormatException {
    return null;
  }
  final command = decoded is Map ? decoded['command'] : null;
  if (command is! List || command.isEmpty) return null;
  if (command.first == kCodexPatchTool) {
    return command.length > 1 && command[1] is String
        ? command[1] as String
        : null;
  }
  final script = command.last;
  if (script is! String || !_invokesPatch.hasMatch(script)) return null;
  final start = script.indexOf(_beginPatch);
  if (start < 0) return null;
  final end = script.indexOf(_endPatch, start);
  return end < 0
      ? script.substring(start)
      : script.substring(start, end + _endPatch.length);
}

const String _beginPatch = '*** Begin Patch';
const String _endPatch = '*** End Patch';

/// `apply_patch` as a command of its own in a script, not a word in a string.
final RegExp _invokesPatch = RegExp(r'(^|&&|;|\n)\s*apply_patch\b');

String? _header(String line, String prefix) {
  if (!line.startsWith(prefix)) return null;
  final rest = line.substring(prefix.length).trim();
  return rest.isEmpty ? null : rest;
}
