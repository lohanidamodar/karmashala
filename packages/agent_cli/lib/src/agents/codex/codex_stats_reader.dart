import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../cli_detection/domain/session_stats.dart';
import '../adapter/agent_stats.dart';

/// Session stats read out of a Codex rollout, without decoding the rollout.
///
/// A separate reader rather than an extension of `CodexStoreReader`, and the
/// separation is the point. That reader caches a rollout on its **size alone**
/// and never looks past the opening `session_meta`, because every field it
/// wants is first-wins from the head of the file; folding the tally into it
/// would make each detection sweep read every rollout to the end, which is the
/// exact cost its comments exist to explain away.
///
/// ## Why a rollout is big, and why that does not have to cost anything
///
/// The owner's largest rollout is **120 MB in 1,392 lines**. Eleven of those
/// lines are over 500 KB and the largest is **22 MB** — they are pasted IDE
/// context blocks, written twice each (once as `response_item`, once as
/// `event_msg`). Every `token_count` record in that file put together is
/// **126 KB, one thousandth of it**. The stats were never the big part; the
/// big part is a handful of user messages, and decoding a 22 MB line to
/// discover it is not a usage record is the entire cost.
///
/// So nothing here decodes a line it does not need, and nothing here builds a
/// `String` out of one. **Counts come from a prefix scan.** A record's kind is
/// at the head of its line — `"payload":{"type":"` never appears past
/// **byte 82** across the 51,060 lines of this machine's 52 rollouts — so only
/// the first [_prefixCap] bytes of each line are ever copied and the rest is
/// skipped to the newline. A line whose prefix does not classify is simply not
/// counted; nothing throws. **Only usage records are decoded**, and every one
/// of them is: `total_token_usage` is cumulative, so the step between two
/// consecutive records is what one turn cost, and the last one is the total.
/// The reader once decoded only the last record, found from the tail; per-turn
/// tokens need them all, and they are the thousandth of the file that was
/// never the cost.
///
/// Measured on that 120 MB rollout, for the same answer (18 turns, 279 tool
/// calls, the same cumulative total):
///
/// | | wall | bytes into Strings | lines decoded |
/// | --- | --- | --- | --- |
/// | decode every line | 1,882 ms | 114.9 MB | 1,392 |
/// | prefix scan, usage records only | **156 ms** | **345 KB** | the usage records |
///
/// That is what retired the isolate this used to need: 156 ms spread over
/// ~1,900 chunk callbacks blocks no frame, so there is nothing left to move
/// off the UI isolate.
class CodexStatsReader implements SessionStatsReader {
  CodexStatsReader({CodexStatsCache? cache})
    : _cache = cache ?? CodexStatsCache.shared;

  final CodexStatsCache _cache;

  /// Bytes pulled off the disk by this reader, over every read it has run.
  int bytesRead = 0;

  /// Lines handed to `jsonDecode`. The cost claim, and what a test asserts on:
  /// a read decodes its usage records and **nothing else**, whatever its size.
  int linesDecoded = 0;

  /// What one rollout adds up to, resumed from wherever the last read stopped.
  ///
  /// Null when the file cannot be stat'ed. A second read of an untouched
  /// rollout costs a `stat` and nothing else.
  @override
  Future<SessionStats?> readSessionStats(String filePath) async {
    final file = File(filePath);
    final FileStat stat;
    try {
      stat = await file.stat();
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
    final counters = resume?.counters.copy() ?? CodexStatsCounters();
    final from = resume?.consumed ?? 0;

    final scan = await _scanForward(file, from: from, counters: counters);
    if (!scan.readable) return counters.toStats();

    _cache._byPath[filePath] = _CodexStatsEntry(
      size: stat.size,
      modified: stat.modified,
      consumed: scan.consumed,
      counters: counters,
    );
    return counters.toStats();
  }

  /// One resumable pass for the counts, copying at most [_prefixCap] bytes of
  /// any line and skipping the rest to the newline.
  ///
  /// Byte-accurate rather than `LineSplitter`, because the offset to resume
  /// from has to land on a line boundary: a rollout whose last line has no
  /// newline yet is a record the CLI is still flushing, and must be read whole
  /// next time.
  ///
  /// The buffer is fixed and reused, so a 22 MB pasted-context line costs a
  /// scan for its newline and not one byte of allocation. Only a line whose
  /// head says it is a usage record is allowed to grow past [_prefixCap].
  Future<_CodexScan> _scanForward(
    File file, {
    required int from,
    required CodexStatsCounters counters,
  }) async {
    var consumed = from;
    final buffer = Uint8List(_lineCap);
    var held = 0;
    // Bytes of the current line, including the part deliberately not kept —
    // `consumed` has to advance by the whole line, not by what was copied.
    var lineLength = 0;
    var cap = _prefixCap;
    var classified = false;

    // Loops rather than copying once, because [cap] can be raised *by* this
    // copy: a whole line usually arrives inside one chunk, and stopping at the
    // 256-byte cap in the same call that decided the line was worth keeping
    // whole would hand `_count` a truncated record to fail on.
    void keep(List<int> chunk, int start, int end) {
      lineLength += end - start;
      var at = start;
      while (at < end) {
        final room = cap - held;
        if (room <= 0) return;
        final take = end - at;
        final n = take < room ? take : room;
        buffer.setRange(held, held + n, chunk, at);
        held += n;
        at += n;
        // Once the head is long enough to have shown what the record is,
        // decide whether the body is worth keeping. Only a usage record is.
        if (!classified && held >= _prefixCap) {
          classified = true;
          if (_containsIn(buffer, held, _usageMarker)) cap = _lineCap;
        }
      }
    }

    try {
      await for (final chunk in file.openRead(from)) {
        bytesRead += chunk.length;
        var start = 0;
        for (var i = 0; i < chunk.length; i++) {
          if (chunk[i] != _newline) continue;
          keep(chunk, start, i);
          consumed += lineLength + 1;
          _count(buffer, held, counters);
          held = 0;
          lineLength = 0;
          cap = _prefixCap;
          classified = false;
          start = i + 1;
        }
        if (start < chunk.length) keep(chunk, start, chunk.length);
      }
      // Whatever is left has no newline after it: a record still being written.
      // Deliberately not counted as consumed.
    } catch (_) {
      return _CodexScan(consumed: consumed, readable: false);
    }
    return _CodexScan(consumed: consumed, readable: true);
  }

  void _count(Uint8List head, int length, CodexStatsCounters counters) {
    if (length == 0) return;
    counters.markTime(_timestampIn(head, length));
    if (_containsIn(head, length, _userMessageMarker)) {
      counters.openTurn();
      return;
    }
    if (_containsIn(head, length, _agentMessageMarker)) {
      counters.replies++;
      return;
    }
    for (final marker in _toolCallMarkers) {
      final at = _indexIn(head, length, marker);
      if (at < 0) continue;
      counters.toolCalls++;
      final name =
          _stringAfter(head, length, _nameMarker, from: at + marker.length) ??
          (identical(marker, _toolCallMarkers.last) ? 'local_shell' : null);
      if (name != null) {
        counters.toolCallsByName[name] =
            (counters.toolCallsByName[name] ?? 0) + 1;
      }
      return;
    }
    if (_containsIn(head, length, _usageMarker)) {
      _decodeUsage(Uint8List.sublistView(head, 0, length), counters);
    }
  }

  void _decodeUsage(List<int> line, CodexStatsCounters counters) {
    linesDecoded++;
    try {
      final decoded = jsonDecode(utf8.decode(line, allowMalformed: true));
      if (decoded is! Map) return;
      final payload = decoded['payload'];
      if (payload is! Map || payload['type'] != 'token_count') return;
      _readUsageInfo(payload['info'], counters);
    } on Object {
      // A fragment, or a shape we do not know. The tally keeps what it had.
    }
  }

  /// The envelope's own `timestamp`, read out of the head without decoding it.
  static String? _timestampIn(Uint8List head, int length) =>
      _stringAfter(head, length, _timestampMarker);

  /// The string value that follows [marker], when it closes inside the head.
  /// A value cut off by the prefix cap is not recorded rather than truncated.
  static String? _stringAfter(
    Uint8List head,
    int length,
    Uint8List marker, {
    int from = 0,
  }) {
    var at = -1;
    for (var i = from; i <= length - marker.length; i++) {
      if (_matchesAt(head, marker, i)) {
        at = i;
        break;
      }
    }
    if (at < 0) return null;
    final start = at + marker.length;
    var to = start;
    while (to < length && head[to] != _quote) {
      to++;
    }
    if (to <= start || to >= length) return null;
    return utf8.decode(
      Uint8List.sublistView(head, start, to),
      allowMalformed: true,
    );
  }
}

/// Bytes of a line kept for classification. The marker this reads never appears
/// past byte 82 in any of this machine's 51,060 rollout lines, so this is
/// threefold headroom rather than a guess.
const int _prefixCap = 256;

/// The most of any one line that is ever held, which is what a usage record
/// needs (~721 bytes) plus room to grow.
const int _lineCap = 8 * 1024;

const int _newline = 0x0A;
const int _quote = 0x22;

final Uint8List _usageMarker = _bytes('"payload":{"type":"token_count"');
final Uint8List _userMessageMarker = _bytes('"payload":{"type":"user_message"');
final Uint8List _agentMessageMarker = _bytes(
  '"payload":{"type":"agent_message"',
);
final List<Uint8List> _toolCallMarkers = [
  _bytes('"payload":{"type":"function_call"'),
  _bytes('"payload":{"type":"custom_tool_call"'),
  _bytes('"payload":{"type":"local_shell_call"'),
];
final Uint8List _timestampMarker = _bytes('"timestamp":"');

/// Escaped inside `arguments`, so this only matches the record's own field.
final Uint8List _nameMarker = _bytes('"name":"');

Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));

bool _matchesAt(List<int> haystack, List<int> needle, int at) {
  if (at + needle.length > haystack.length) return false;
  for (var i = 0; i < needle.length; i++) {
    if (haystack[at + i] != needle[i]) return false;
  }
  return true;
}

/// [needle]'s offset within the first [length] bytes of [haystack], or -1.
///
/// Takes a length rather than a view because the scan reuses one buffer: a
/// `sublist` per line would be the allocation this whole reader avoids.
int _indexIn(List<int> haystack, int length, List<int> needle) {
  final last = length - needle.length;
  for (var i = 0; i <= last; i++) {
    if (_matchesAt(haystack, needle, i)) return i;
  }
  return -1;
}

bool _containsIn(List<int> haystack, int length, List<int> needle) =>
    _indexIn(haystack, length, needle) >= 0;

void _readUsageInfo(Object? info, CodexStatsCounters counters) {
  if (info is! Map) return;
  final total = info['total_token_usage'];
  if (total is Map) {
    counters.inputTokens = _int(total['input_tokens']) ?? counters.inputTokens;
    counters.cachedInputTokens =
        _int(total['cached_input_tokens']) ?? counters.cachedInputTokens;
    counters.cacheWriteTokens =
        _int(total['cache_write_input_tokens']) ?? counters.cacheWriteTokens;
    final output = _int(total['output_tokens']) ?? counters.outputTokens;
    final reasoning =
        _int(total['reasoning_output_tokens']) ?? counters.reasoningTokens;
    counters.chargeTurn(
      output: (output ?? 0) - (counters.outputTokens ?? 0),
      reasoning: (reasoning ?? 0) - (counters.reasoningTokens ?? 0),
    );
    counters.outputTokens = output;
    counters.reasoningTokens = reasoning;
  }
  final last = info['last_token_usage'];
  if (last is Map) {
    // Codex's `input_tokens` already includes the cached part.
    counters.lastPromptTokens =
        _int(last['input_tokens']) ?? counters.lastPromptTokens;
  }
  counters.contextWindow =
      _int(info['model_context_window']) ?? counters.contextWindow;
}

int? _int(Object? value) => value is num ? value.toInt() : null;

class _CodexScan {
  const _CodexScan({required this.consumed, required this.readable});

  final int consumed;

  /// False when the read threw. Its partial answer is still returned, but it is
  /// not remembered — a locked file gets another chance next time.
  final bool readable;
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
  int? lastPromptTokens;
  Map<String, int> toolCallsByName = {};

  /// Each prompt's share of the cumulative totals: the step between the usage
  /// record that closed it and the one before, so a turn with several model
  /// calls adds up its calls and a resumed read continues from the cached
  /// total rather than from zero.
  List<int> outputPerTurn = [];
  List<int> reasoningPerTurn = [];

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
    ..lastPromptTokens = lastPromptTokens
    ..toolCallsByName = {...toolCallsByName}
    ..outputPerTurn = [...outputPerTurn]
    ..reasoningPerTurn = [...reasoningPerTurn]
    ..firstAt = firstAt
    ..lastAt = lastAt;

  void openTurn() {
    turns++;
    outputPerTurn.add(0);
    reasoningPerTurn.add(0);
  }

  /// A usage record's step over the previous one, charged to the open turn. A
  /// record before any prompt — a resumed conversation's replayed total — opens
  /// one; a step below zero is a reset, and counts as nothing.
  void chargeTurn({required int output, required int reasoning}) {
    if (outputPerTurn.isEmpty) {
      outputPerTurn.add(0);
      reasoningPerTurn.add(0);
    }
    outputPerTurn[outputPerTurn.length - 1] += output < 0 ? 0 : output;
    reasoningPerTurn[reasoningPerTurn.length - 1] += reasoning < 0
        ? 0
        : reasoning;
  }

  void markTime(String? timestamp) {
    if (timestamp == null || timestamp.isEmpty) return;
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
      toolCallsByName: Map.unmodifiable(toolCallsByName),
      lastPromptTokens: lastPromptTokens,
      outputTokensPerTurn: input == null
          ? null
          : List.unmodifiable(outputPerTurn),
      reasoningTokensPerTurn: input == null
          ? null
          : List.unmodifiable(reasoningPerTurn),
    );
  }
}
