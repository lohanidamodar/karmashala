import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../agents/domain/agent_ids.dart';
import '../../environments/domain/environment_path.dart';
import '../domain/detected_session.dart';
import '../domain/session_stats.dart';

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
        final FileStat stat;
        try {
          stat = await fileEntity.stat();
        } on Object {
          continue;
        }
        final entry = await _readEntry(fileEntity, stat);
        final session = entry.toSession(
          fileEntity.path,
          claudeHome,
          environmentId,
        );
        if (session != null) sessions.add(session);
      }
    }
    return sessions;
  }

  /// What one session's own file adds up to, resumed from wherever the last
  /// read of it stopped.
  ///
  /// The same read [read] does, narrowed to one file and answered out of the
  /// same cache — **not** a second pass. A file the store scan has already
  /// walked costs a `stat` and nothing else, which is what makes opening the
  /// stats dialog twice free; see `claude_store_stats_test.dart`.
  ///
  /// Null only when the file cannot be stat'ed.
  Future<SessionStats?> readSessionStats(String filePath) async {
    final file = File(filePath);
    final FileStat stat;
    try {
      stat = await file.stat();
    } on Object {
      return null;
    }
    if (stat.type == FileSystemEntityType.notFound) return null;
    return (await _readEntry(file, stat)).stats;
  }

  Future<_ClaudeStoreEntry> _readEntry(File file, FileStat stat) async {
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
      return cached;
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
    // Carried by reference and mutated in place: the counts resume with the
    // byte offset rather than being recomputed, which is the whole point of
    // keeping them here instead of in a second reader.
    final counters = resume?.counters ?? _ClaudeCounters();

    var readable = true;
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
              counters.countUser(json);
            case 'assistant':
              counters.countAssistant(json);
          }
          counters.markTime(json['timestamp']);
          cwd ??= json['cwd'] as String?;
        }
        pending.addAll(chunk.sublist(start));
      }
      // Whatever is left has no newline after it: a record still being written.
      // It is deliberately not counted as consumed, so the next scan reads it
      // whole rather than resuming inside it.
    } catch (_) {
      // Corrupt or unreadable — keep whatever was collected.
      readable = false;
    }

    final entry = _ClaudeStoreEntry(
      size: stat.size,
      modified: stat.modified,
      consumed: consumed,
      aiTitle: aiTitle,
      customTitle: customTitle,
      preview: preview,
      cwd: cwd,
      entrypoint: entrypoint,
      counters: counters,
    );
    // A file that threw is not remembered, so a locked one is tried again on
    // the next scan rather than being frozen at whatever it managed to say.
    // One that simply has no `cwd` yet *is* remembered: it still grows, and a
    // size change is what brings it back.
    if (readable) _cache._store(path, entry);
    return entry;
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
    required this.counters,
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

  /// The running counts, mutated in place as the file is resumed.
  final _ClaudeCounters counters;

  SessionStats get stats => counters.toStats();

  DetectedSession? toSession(
    String path,
    String claudeHome,
    String environmentId,
  ) {
    final directory = cwd;
    if (directory == null || directory.isEmpty) return null;
    return DetectedSession(
      cli: AgentIds.claudeCode,
      sessionId: p.basenameWithoutExtension(path),
      cwd: EnvironmentPath(environmentId: environmentId, path: directory),
      filePath: path,
      storeHome: claudeHome,
      title: customTitle ?? aiTitle,
      preview: preview,
      modifiedAt: modified,
      entrypoint: entrypoint,
    );
  }
}

/// What one session file adds up to, counted as it is read.
///
/// Mutable and carried by [_ClaudeStoreEntry], so a resumed read continues the
/// tally from where the last one stopped instead of starting over — the same
/// bargain the byte offset makes, applied to the numbers.
class _ClaudeCounters {
  int turns = 0;
  int replies = 0;
  int toolCalls = 0;
  int inputTokens = 0;
  int outputTokens = 0;
  int cacheCreatedTokens = 0;
  int cacheReadTokens = 0;
  bool sawUsage = false;
  DateTime? firstAt;
  DateTime? lastAt;

  /// The `message.id` of the previous `assistant` record. See [countAssistant].
  String? lastReplyId;

  void markTime(Object? timestamp) {
    if (timestamp is! String || timestamp.isEmpty) return;
    final at = DateTime.tryParse(timestamp)?.toUtc();
    if (at == null) return;
    final first = firstAt, last = lastAt;
    if (first == null || at.isBefore(first)) firstAt = at;
    if (last == null || at.isAfter(last)) lastAt = at;
  }

  /// A prompt the user actually sent.
  ///
  /// **Tool results are `user` records too.** In the owner's largest session
  /// there are 3,442 of them against 213 real prompts, so counting the type
  /// alone overstates the turns by sixteen times. Sidechain records belong to a
  /// delegated agent and are counted against its own file, not this one.
  void countUser(Map<String, dynamic> json) {
    if (json['isSidechain'] == true || json['isMeta'] == true) return;
    final message = json['message'];
    if (message is Map) {
      final content = message['content'];
      if (content is List) {
        for (final block in content) {
          if (block is Map && block['type'] == 'tool_result') return;
        }
      }
    }
    turns++;
  }

  /// One model reply, and the tool calls it made.
  ///
  /// **A single API response is written as several records**, one per content
  /// block — thinking, text, tool_use — and every one of them repeats the same
  /// `usage`. Summing them multiplies the tokens by up to ten. The blocks for
  /// one message are written together, so skipping a repeat of the previous
  /// record's `message.id` costs one string and catches 1,512 of the 1,530
  /// duplicate groups in the owner's largest session. The remainder are records
  /// a resume replayed verbatim, tens of lines apart; catching those would mean
  /// remembering every id in every file, which is a much worse trade.
  ///
  /// Tool calls are counted from **every** record, because each holds a
  /// different block — the dedup is about `usage`, not about content.
  void countAssistant(Map<String, dynamic> json) {
    if (json['isSidechain'] == true) return;
    final message = json['message'];
    if (message is! Map) return;

    final content = message['content'];
    if (content is List) {
      for (final block in content) {
        if (block is Map && block['type'] == 'tool_use') toolCalls++;
      }
    }

    final id = message['id'];
    final replyId = id is String && id.isNotEmpty ? id : null;
    if (replyId != null && replyId == lastReplyId) return;
    lastReplyId = replyId;
    replies++;

    final usage = message['usage'];
    if (usage is! Map) return;
    sawUsage = true;
    inputTokens += _int(usage['input_tokens']);
    outputTokens += _int(usage['output_tokens']);
    cacheCreatedTokens += _int(usage['cache_creation_input_tokens']);
    cacheReadTokens += _int(usage['cache_read_input_tokens']);
  }

  static int _int(Object? value) => value is num ? value.toInt() : 0;

  SessionStats toStats() => SessionStats(
    source: SessionStatsSource.localStore,
    turns: turns,
    replies: replies,
    toolCalls: toolCalls,
    // Absent rather than zero when no record carried a `usage` block: a
    // session whose tokens were never written is not a session that used none.
    tokens: sawUsage
        ? TokenTally(
            input: inputTokens,
            output: outputTokens,
            cacheCreated: cacheCreatedTokens,
            cacheRead: cacheReadTokens,
          )
        : TokenTally.unknown,
    firstActivityAt: firstAt,
    lastActivityAt: lastAt,
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
