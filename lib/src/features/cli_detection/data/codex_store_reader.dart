import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../agents/domain/agent_ids.dart';
import '../../environments/domain/environment_path.dart';
import '../domain/detected_session.dart';
import 'store_scan_slots.dart';
import 'store_session_reader.dart';

/// Reads Codex sessions from a `.codex` store directory.
///
/// Ported from the reference Karmashala CLI. Codex has no project list: each
/// `<codexHome>/sessions/[YYYY/MM/DD/]rollout-*.jsonl` records its `cwd` in a
/// leading `session_meta` line, and the session's editable label is the
/// `thread_name` in `<codexHome>/session_index.jsonl`.
/// What a rollout was last seen to say, so an unchanged one costs a `stat`.
///
/// Shared by default: the saving is across *scans*, and a fresh cache every
/// pass would read every rollout again — which is the cost this exists to
/// remove. A test passes its own so it starts cold.
class CodexRolloutCache {
  CodexRolloutCache();

  static final CodexRolloutCache shared = CodexRolloutCache();

  final Map<String, _CachedRollout> _byPath = {};

  void clear() => _byPath.clear();
}

class _CachedRollout {
  const _CachedRollout({required this.meta, required this.size});

  final _CodexMeta meta;

  /// The size the file had when it was read. A file that has only *grown*
  /// still says the same thing — see [CodexStoreReader._readRollout].
  final int size;
}

class CodexStoreReader implements StoreSessionReader {
  CodexStoreReader({CodexRolloutCache? cache})
    : _cache = cache ?? CodexRolloutCache.shared;

  final CodexRolloutCache _cache;

  /// Bytes actually pulled off the disk, over every scan this reader has run.
  ///
  /// Exposed rather than inferred, the way [ClaudeStoreReader] exposes it: the
  /// claim is that a scan costs what *changed*, and a number nobody can read is
  /// a claim nobody can check.
  int bytesRead = 0;

  /// [directories] is ignored, and cannot be honoured: Codex's paths carry a
  /// **date**, not a working directory, so which rollouts belong to a
  /// repository is only knowable by opening them. That is what makes this the
  /// expensive store, and why [slots] and the rollout cache both matter more
  /// here than for Claude — the recursion below is over `YYYY/MM/DD/`, which is
  /// the store's own shape and stays.
  @override
  Future<List<DetectedSession>> read(
    String codexHome,
    String environmentId, {
    Set<String>? directories,
    StoreScanSlots? slots,
  }) async {
    final sessionsDir = Directory(p.join(codexHome, 'sessions'));
    if (!await sessionsDir.exists()) return const [];

    final threadNames = await _readThreadNames(codexHome);
    final found = <DetectedSession?>[];
    final reads = <Future<void>>[];

    await for (final entity in sessionsDir.list(recursive: true)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!name.startsWith('rollout-') || !name.endsWith('.jsonl')) continue;

      final slot = found.length;
      found.add(null);
      Future<void> readRollout() async {
        found[slot] = await _readSession(
          entity,
          codexHome,
          environmentId,
          threadNames,
        );
      }

      reads.add(slots == null ? readRollout() : slots.run(readRollout));
    }
    await Future.wait(reads);
    return [for (final session in found) ?session];
  }

  Future<DetectedSession?> _readSession(
    File file,
    String codexHome,
    String environmentId,
    Map<String, String> threadNames,
  ) async {
    final FileStat stat;
    try {
      stat = await file.stat();
    } on Object {
      return null;
    }
    final meta = await _readRollout(file, stat);
    if (meta == null) return null;
    return DetectedSession(
      cli: AgentIds.codex,
      sessionId: meta.id,
      cwd: EnvironmentPath(environmentId: environmentId, path: meta.cwd),
      filePath: file.path,
      storeHome: codexHome,
      title: threadNames[meta.id],
      preview: meta.preview,
      startedAt: meta.startedAt,
      modifiedAt: stat.modified,
    );
  }

  /// The `session_meta` a rollout opens with.
  ///
  /// Cached on the file's size, because **every field here is first-wins from
  /// the head of the file**: `cwd`, `id`, `startedAt` and the preview all come
  /// from the opening lines and are never rewritten. A rollout that has grown
  /// since the last scan therefore still says exactly what it said, and only
  /// one that *shrank* — a file replaced under the same name — has to be read
  /// again.
  ///
  /// That is a stronger rule than [ClaudeStoreReader]'s, which must still read
  /// the tail for a title that gets re-stamped. Here there is nothing in the
  /// tail worth having.
  ///
  /// Without this, a scan re-decoded up to 400 lines of every rollout every
  /// time it ran. On the owner's machine that was **39% of the app's entire
  /// idle CPU** — measured in a profile build with the window untouched.
  Future<_CodexMeta?> _readRollout(File file, FileStat stat) async {
    final cached = _cache._byPath[file.path];
    if (cached != null && stat.size >= cached.size) {
      return cached.meta;
    }

    String? cwd;
    String? id;
    DateTime? startedAt;
    String preview = '';
    var lines = 0;
    try {
      await for (final line
          in file
              .openRead()
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        bytesRead += line.length + 1;
        if (lines++ > 400 && cwd != null) break;
        if (line.isEmpty) continue;
        final Map<String, dynamic> json;
        try {
          final decoded = jsonDecode(line);
          if (decoded is! Map<String, dynamic>) continue;
          json = decoded;
        } on FormatException {
          continue;
        }
        if (json['type'] == 'session_meta') {
          final payload = json['payload'];
          if (payload is Map) {
            cwd ??= payload['cwd'] as String?;
            id ??= payload['id'] as String?;
            // The payload's own timestamp, not the envelope's. They are not the
            // same moment: in the owner's rollout the conversation began at
            // 10:11:12.953Z and the line recording that was flushed at
            // 10:11:42.945Z — thirty seconds later. Attribution compares this
            // against when a session row was written, so it wants the start.
            startedAt ??=
                _parseTime(payload['timestamp']) ??
                _parseTime(json['timestamp']);
          }
        }
        cwd ??= json['cwd'] as String?;
        id ??= json['id'] as String?;
        if (preview.isEmpty) preview = _extractUserMessage(json);
      }
    } catch (_) {}

    if (cwd == null || cwd.isEmpty) return null;
    id ??= _idFromFileName(p.basename(file.path));
    final meta = _CodexMeta(
      cwd: cwd,
      id: id,
      preview: preview,
      startedAt: startedAt,
    );
    // Only a complete answer is cached. A rollout still being written may not
    // have its `session_meta` yet, and remembering the miss would keep it
    // missing.
    _cache._byPath[file.path] = _CachedRollout(meta: meta, size: stat.size);
    return meta;
  }

  /// An ISO-8601 instant, in UTC, or null for anything else.
  static DateTime? _parseTime(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return DateTime.tryParse(value)?.toUtc();
  }

  /// `rollout-2026-05-25T16-21-53-<uuid>.jsonl` → `<uuid>`.
  static String _idFromFileName(String fileName) {
    final stem = fileName
        .replaceFirst('rollout-', '')
        .replaceFirst('.jsonl', '');
    final uuid = RegExp(r'[0-9a-fA-F-]{36}$').firstMatch(stem);
    return uuid?.group(0) ?? stem;
  }

  static String _extractUserMessage(Map<String, dynamic> json) {
    final payload = json['payload'];
    if (payload is! Map) return '';
    if (payload['type'] != 'message' || payload['role'] != 'user') return '';
    final content = payload['content'];
    if (content is List) {
      for (final block in content) {
        if (block is Map && block['type'] == 'input_text') {
          final text = block['text'];
          if (text is String && text.trim().isNotEmpty) {
            final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
            return cleaned.length > 120
                ? '${cleaned.substring(0, 119)}…'
                : cleaned;
          }
        }
      }
    }
    return '';
  }

  Future<Map<String, String>> _readThreadNames(String codexHome) async {
    final index = File(p.join(codexHome, 'session_index.jsonl'));
    if (!await index.exists()) return const {};
    final names = <String, String>{};
    try {
      await for (final line
          in index
              .openRead()
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (line.isEmpty) continue;
        try {
          final decoded = jsonDecode(line);
          if (decoded is Map<String, dynamic>) {
            final id = decoded['id'];
            final name = decoded['thread_name'];
            if (id is String && name is String && name.trim().isNotEmpty) {
              names[id] = name;
            }
          }
        } on FormatException {
          continue;
        }
      }
    } catch (_) {}
    return names;
  }
}

class _CodexMeta {
  const _CodexMeta({
    required this.cwd,
    required this.id,
    required this.preview,
    this.startedAt,
  });
  final String cwd;
  final String id;
  final String preview;
  final DateTime? startedAt;
}
