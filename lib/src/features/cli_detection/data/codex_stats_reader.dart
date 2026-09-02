import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../domain/session_stats.dart';

/// Session stats read out of a Codex rollout.
///
/// A separate reader rather than an extension of `CodexStoreReader`, and the
/// separation is the point. That reader caches a rollout on its **size alone**
/// and never looks past the opening `session_meta`, because every field it
/// wants is first-wins from the head of the file; folding the tally into it
/// would make each detection sweep read every rollout to the end, which is the
/// exact cost its comments exist to explain away. This reads the tail, and only
/// when someone asks for it.
///
/// What the rollout records, and why each is trustworthy:
///
/// | Field | Source | Notes |
/// | --- | --- | --- |
/// | tokens | `event_msg` / `token_count` → `info.total_token_usage` | **cumulative**, so the last one wins |
/// | context window | the same record's `info.model_context_window` | Claude Code writes no equivalent |
/// | turns | `event_msg` / `user_message` | one per prompt |
/// | tool calls | `response_item` of `function_call`, `custom_tool_call`, `local_shell_call` | |
///
/// Cumulative totals are what makes this cheap to resume: a reader that stops
/// at byte *n* and continues from there later still ends on the same last
/// `token_count` a full read would have found.
class CodexStatsReader {
  CodexStatsReader({CodexStatsCache? cache, this.inBackground = true})
    : _cache = cache ?? CodexStatsCache.shared;

  final CodexStatsCache _cache;

  /// Whether the scan runs on a spawned isolate.
  ///
  /// On by default because the first read of a rollout is unbounded — the
  /// owner's largest is **120 MB** — and decoding that many lines on the UI
  /// isolate drops frames for as long as it takes. Off only in a test that
  /// wants a deterministic single-isolate run.
  final bool inBackground;

  /// Bytes pulled off the disk by this reader, over every read it has run.
  int bytesRead = 0;

  /// What one rollout adds up to, resumed from wherever the last read stopped.
  ///
  /// Null when the file cannot be stat'ed. A second read of an untouched
  /// rollout costs a `stat` and nothing else.
  Future<SessionStats?> readSessionStats(String filePath) async {
    final FileStat stat;
    try {
      stat = await File(filePath).stat();
    } on Object {
      return null;
    }
    if (stat.type == FileSystemEntityType.notFound) return null;

    final cached = _cache._byPath[filePath];
    if (cached != null &&
        cached.size == stat.size &&
        cached.modified == stat.modified) {
      return cached.counters.toStats();
    }

    // Only a rollout that *shrank* is read again from the top: a file replaced
    // under the same name is a different conversation.
    final resume = cached != null && stat.size >= cached.consumed
        ? cached
        : null;
    final request = _CodexScanRequest(
      path: filePath,
      from: resume?.consumed ?? 0,
      counters: resume?.counters.copy() ?? CodexStatsCounters(),
    );

    final result = inBackground
        ? await Isolate.run(() => _scanCodexRollout(request))
        : await _scanCodexRollout(request);
    bytesRead += result.bytesRead;
    if (!result.readable) return result.counters.toStats();

    _cache._byPath[filePath] = _CodexStatsEntry(
      size: stat.size,
      modified: stat.modified,
      consumed: result.consumed,
      counters: result.counters,
    );
    return result.counters.toStats();
  }
}

/// What each rollout was last seen to say, and how much of it was read.
///
/// Shared by default: the saving is across *openings* of the stats dialog, and
/// a fresh cache each time would re-read the rollout it just read.
class CodexStatsCache {
  CodexStatsCache();

  static final CodexStatsCache shared = CodexStatsCache();

  final Map<String, _CodexStatsEntry> _byPath = {};

  /// Entries held — the cost claim, and what a test asserts on.
  int get length => _byPath.length;

  void clear() => _byPath.clear();
}

class _CodexStatsEntry {
  const _CodexStatsEntry({
    required this.size,
    required this.modified,
    required this.consumed,
    required this.counters,
  });

  final int size;
  final DateTime modified;

  /// Bytes up to and including the last complete line, so a resume can never
  /// start inside a record the CLI was still writing.
  final int consumed;

  final CodexStatsCounters counters;
}

/// The running tally for one rollout.
///
/// Public and plain so it can cross an isolate boundary with the scan that
/// produced it.
class CodexStatsCounters {
  CodexStatsCounters();

  int turns = 0;
  int replies = 0;
  int toolCalls = 0;

  /// The newest `total_token_usage`, which is cumulative for the whole
  /// conversation — so this is assignment, not addition.
  int? inputTokens;
  int? cachedInputTokens;
  int? cacheWriteTokens;
  int? outputTokens;
  int? reasoningTokens;
  int? contextWindow;

  DateTime? firstAt;
  DateTime? lastAt;

  CodexStatsCounters copy() => CodexStatsCounters()
    ..turns = turns
    ..replies = replies
    ..toolCalls = toolCalls
    ..inputTokens = inputTokens
    ..cachedInputTokens = cachedInputTokens
    ..cacheWriteTokens = cacheWriteTokens
    ..outputTokens = outputTokens
    ..reasoningTokens = reasoningTokens
    ..contextWindow = contextWindow
    ..firstAt = firstAt
    ..lastAt = lastAt;

  void markTime(Object? timestamp) {
    if (timestamp is! String || timestamp.isEmpty) return;
    final at = DateTime.tryParse(timestamp)?.toUtc();
    if (at == null) return;
    final first = firstAt, last = lastAt;
    if (first == null || at.isBefore(first)) firstAt = at;
    if (last == null || at.isAfter(last)) lastAt = at;
  }

  SessionStats toStats() {
    final input = inputTokens;
    final cached = cachedInputTokens ?? 0;
    return SessionStats(
      source: SessionStatsSource.localStore,
      turns: turns,
      replies: replies,
      toolCalls: toolCalls,
      tokens: input == null
          ? TokenTally.unknown
          : TokenTally(
              // Codex counts cache reads *inside* `input_tokens`; the rest of
              // the app reads "input" as what was actually re-sent, so the
              // cached part is subtracted out rather than counted twice.
              input: (input - cached).clamp(0, input),
              output: outputTokens,
              cacheCreated: cacheWriteTokens,
              cacheRead: cachedInputTokens,
              reasoning: reasoningTokens,
            ),
      contextWindow: contextWindow,
      firstActivityAt: firstAt,
      lastActivityAt: lastAt,
    );
  }
}

class _CodexScanRequest {
  const _CodexScanRequest({
    required this.path,
    required this.from,
    required this.counters,
  });

  final String path;
  final int from;
  final CodexStatsCounters counters;
}

class _CodexScanResult {
  const _CodexScanResult({
    required this.counters,
    required this.consumed,
    required this.bytesRead,
    required this.readable,
  });

  final CodexStatsCounters counters;
  final int consumed;
  final int bytesRead;

  /// False when the read threw. Its partial answer is still returned, but it is
  /// not remembered — a locked file gets another chance next time.
  final bool readable;
}

/// One resumable pass over a rollout. Top-level so [Isolate.run] can carry it.
///
/// Byte-accurate rather than `LineSplitter`, because the offset to resume from
/// has to land on a line boundary: a rollout whose last line has no newline yet
/// is a record the CLI is still flushing, and must be read whole next time.
Future<_CodexScanResult> _scanCodexRollout(_CodexScanRequest request) async {
  final counters = request.counters;
  var consumed = request.from;
  var bytesRead = 0;
  var readable = true;

  try {
    final pending = <int>[];
    await for (final chunk in File(request.path).openRead(request.from)) {
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
        _countRecord(json, counters);
      }
      pending.addAll(chunk.sublist(start));
    }
  } catch (_) {
    readable = false;
  }

  return _CodexScanResult(
    counters: counters,
    consumed: consumed,
    bytesRead: bytesRead,
    readable: readable,
  );
}

const _toolCallTypes = {
  'function_call',
  'custom_tool_call',
  'local_shell_call',
};

void _countRecord(Map<String, dynamic> json, CodexStatsCounters counters) {
  counters.markTime(json['timestamp']);
  final payload = json['payload'];
  if (payload is! Map) return;
  final type = payload['type'];

  switch (json['type']) {
    case 'event_msg':
      switch (type) {
        case 'user_message':
          counters.turns++;
        case 'agent_message':
          counters.replies++;
        case 'token_count':
          _countTokens(payload['info'], counters);
      }
    case 'response_item':
      if (_toolCallTypes.contains(type)) counters.toolCalls++;
  }
}

void _countTokens(Object? info, CodexStatsCounters counters) {
  if (info is! Map) return;
  final total = info['total_token_usage'];
  if (total is Map) {
    counters.inputTokens = _int(total['input_tokens']) ?? counters.inputTokens;
    counters.cachedInputTokens =
        _int(total['cached_input_tokens']) ?? counters.cachedInputTokens;
    counters.cacheWriteTokens =
        _int(total['cache_write_input_tokens']) ?? counters.cacheWriteTokens;
    counters.outputTokens =
        _int(total['output_tokens']) ?? counters.outputTokens;
    counters.reasoningTokens =
        _int(total['reasoning_output_tokens']) ?? counters.reasoningTokens;
  }
  counters.contextWindow =
      _int(info['model_context_window']) ?? counters.contextWindow;
}

int? _int(Object? value) => value is num ? value.toInt() : null;
