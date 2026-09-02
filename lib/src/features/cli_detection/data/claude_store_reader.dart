import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../agents/domain/agent_ids.dart';
import '../../environments/domain/environment_path.dart';
import '../domain/detected_session.dart';

/// Reads Claude Code sessions from a `.claude` store directory.
///
/// Ported from the reference Karmashala CLI and adapted to bind sessions to an
/// execution environment. Each `<claudeHome>/projects/<dir>/<id>.jsonl` is one
/// session; the real `cwd` is taken from inside the file (the folder name is a
/// lossy dash-encoding). Title precedence: `custom-title` > `ai-title` > first
/// user message preview. The `entrypoint` field distinguishes SDK-spawned
/// subagents.
class ClaudeStoreReader {
  ClaudeStoreReader({ClaudeStoreCache? cache})
    : _cache = cache ?? ClaudeStoreCache.shared;

  /// What each session file was last seen to say. Shared by default, because
  /// the saving is across *scans* — a fresh cache every pass would read the
  /// whole 2.4 GB again. A test passes its own so it starts cold.
  final ClaudeStoreCache _cache;

  /// Bytes actually pulled off the disk, over every scan this reader has run.
  ///
  /// The cost claim, exposed rather than inferred: the scan's whole purpose is
  /// to be proportional to what changed, and a number nobody can read is a
  /// promise nobody can check.
  int bytesRead = 0;

  /// Reads all sessions under [claudeHome] (a `.claude` directory), tagging them
  /// with [environmentId]. Returns an empty list if the store is absent.
  Future<List<DetectedSession>> read(
    String claudeHome,
    String environmentId,
  ) async {
    final projectsDir = Directory(p.join(claudeHome, 'projects'));
    if (!await projectsDir.exists()) return const [];

    final sessions = <DetectedSession>[];
    await for (final projectEntity in projectsDir.list()) {
      if (projectEntity is! Directory) continue;
      await for (final fileEntity in projectEntity.list()) {
        if (fileEntity is! File || !fileEntity.path.endsWith('.jsonl')) {
          continue;
        }
        final session = await _readSession(
          fileEntity,
          claudeHome,
          environmentId,
        );
        if (session != null) sessions.add(session);
      }
    }
    return sessions;
  }

  Future<DetectedSession?> _readSession(
    File file,
    String claudeHome,
    String environmentId,
  ) async {
    final FileStat stat;
    try {
      stat = await file.stat();
    } on Object {
      return null;
    }

    final path = file.path;
    final cached = _cache._lookup(path);

    // Untouched since we last read it, so it still says what it said. This is
    // the whole scan in the steady state: the owner's store is **2.4 GB across
    // 540 files**, of which one or two are being written, and re-decoding all
    // of it on every slow slot is what made switching sessions and starting one
    // lag. A `stat` answers for the rest.
    if (cached != null &&
        cached.size == stat.size &&
        cached.modified == stat.modified) {
      return cached.toSession(path, claudeHome, environmentId);
    }

    // Grown since — the ordinary case for a live session. Resume from the last
    // complete line rather than re-reading from the top: a title is re-stamped
    // throughout the file (1,034 times in the owner's largest) so only the
    // newest matters, and `cwd`, the preview and the entrypoint are first-wins
    // and already known.
    final resume = cached != null && stat.size >= cached.consumed
        ? cached
        : null;
    var aiTitle = resume?.aiTitle;
    var customTitle = resume?.customTitle;
    var preview = resume?.preview ?? '';
    var cwd = resume?.cwd;
    var entrypoint = resume?.entrypoint;
    var consumed = resume?.consumed ?? 0;

    try {
      // Byte-accurate rather than `LineSplitter`, because the offset to resume
      // from has to be a byte offset that lands on a line boundary — a file
      // whose last line has no newline yet must not be resumed mid-record.
      final pending = <int>[];
      await for (final chunk in file.openRead(consumed)) {
        bytesRead += chunk.length;
        var start = 0;
        for (var i = 0; i < chunk.length; i++) {
          if (chunk[i] != 0x0A) continue;
          pending.addAll(chunk.sublist(start, i));
          start = i + 1;
          consumed += pending.length + 1;
          final line = utf8.decode(pending, allowMalformed: true);
          pending.clear();
          if (line.isEmpty) continue;
          final Map<String, dynamic> json;
          try {
            final decoded = jsonDecode(line);
            if (decoded is! Map<String, dynamic>) continue;
            json = decoded;
          } on FormatException {
            continue;
          }
          switch (json['type']) {
            case 'ai-title':
              final t = json['aiTitle'];
              if (t is String && t.trim().isNotEmpty) aiTitle = t;
            case 'custom-title':
              final t = json['customTitle'];
              if (t is String && t.trim().isNotEmpty) customTitle = t;
            case 'user':
              if (preview.isEmpty) preview = _extractUserMessage(json);
              cwd ??= json['cwd'] as String?;
              if (entrypoint == null) {
                final ep = json['entrypoint'];
                if (ep is String && ep.isNotEmpty) entrypoint = ep;
              }
          }
          cwd ??= json['cwd'] as String?;
        }
        pending.addAll(chunk.sublist(start));
      }
      // Whatever is left has no newline after it: a record still being written.
      // It is deliberately not counted as consumed, so the next scan reads it
      // whole rather than resuming inside it.
    } catch (_) {
      // Corrupt or unreadable — keep whatever was collected.
    }

    if (cwd == null || cwd.isEmpty) return null;

    final entry = _ClaudeStoreEntry(
      size: stat.size,
      modified: stat.modified,
      consumed: consumed,
      aiTitle: aiTitle,
      customTitle: customTitle,
      preview: preview,
      cwd: cwd,
      entrypoint: entrypoint,
    );
    _cache._store(path, entry);
    return entry.toSession(path, claudeHome, environmentId);
  }

  static String _extractUserMessage(Map<String, dynamic> entry) {
    final msg = entry['message'];
    if (msg is String) return _truncate(msg);
    if (msg is Map<String, dynamic>) {
      final content = msg['content'];
      if (content is String) return _truncate(content);
      if (content is List) {
        for (final part in content) {
          if (part is Map<String, dynamic>) {
            final text = part['text'];
            if (text is String && text.trim().isNotEmpty) {
              return _truncate(text);
            }
          } else if (part is String && part.trim().isNotEmpty) {
            return _truncate(part);
          }
        }
      }
    }
    return '';
  }

  static String _truncate(String s, [int max = 120]) {
    final trimmed = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (trimmed.length <= max) return trimmed;
    return '${trimmed.substring(0, max - 1)}…';
  }
}

/// What one session file was last seen to say, and how much of it was read.
class _ClaudeStoreEntry {
  _ClaudeStoreEntry({
    required this.size,
    required this.modified,
    required this.consumed,
    required this.aiTitle,
    required this.customTitle,
    required this.preview,
    required this.cwd,
    required this.entrypoint,
  });

  final int size;
  final DateTime modified;

  /// Bytes up to and including the last complete line. Never the file's size
  /// when it ends mid-record, so a resume cannot start inside one.
  final int consumed;

  final String? aiTitle;
  final String? customTitle;
  final String preview;
  final String? cwd;
  final String? entrypoint;

  DetectedSession toSession(
    String path,
    String claudeHome,
    String environmentId,
  ) => DetectedSession(
    cli: AgentIds.claudeCode,
    sessionId: p.basenameWithoutExtension(path),
    cwd: EnvironmentPath(environmentId: environmentId, path: cwd!),
    filePath: path,
    storeHome: claudeHome,
    title: customTitle ?? aiTitle,
    preview: preview,
    modifiedAt: modified,
    entrypoint: entrypoint,
  );
}

/// Remembers what each session file said, so a scan re-reads only what moved.
///
/// A store scan runs on the status registry's slow slot whenever any session
/// row is still waiting for its CLI's name. Without this it decoded every line
/// of every file each time — measured on the owner's machine at **2.4 GB across
/// 540 files** — which is what made switching sessions and starting one lag.
class ClaudeStoreCache {
  /// The process-wide one. A scan is only cheaper than the last if it remembers
  /// across passes.
  static final ClaudeStoreCache shared = ClaudeStoreCache();

  final Map<String, _ClaudeStoreEntry> _byPath = {};

  _ClaudeStoreEntry? _lookup(String path) => _byPath[path];

  void _store(String path, _ClaudeStoreEntry entry) => _byPath[path] = entry;

  /// Entries held — the cost claim, and what a test asserts on.
  int get length => _byPath.length;

  void clear() => _byPath.clear();
}
