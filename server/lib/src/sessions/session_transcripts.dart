import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:agent_cli/read.dart'
    show
        CliTranscriptTail,
        CompactionBoundary,
        SubagentRef,
        TranscriptMessage,
        readSubagentTranscript,
        subagentsDirectoryFor,
        transcriptFileFor;
import 'package:path/path.dart' as p;
import 'package:agent_cli/stream.dart' show ToolActivity;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/transcript.dart' show ChatViewEvidence;

import 'session_records.dart';

/// One client link, as transcript watches see it: a notice goes to it alone.
abstract interface class TranscriptWatchLink {
  void tell(List<DataChange> changes);
}

/// **Sessions' transcripts, read on this machine for any client**
/// (`sessions.transcript`, Stage 0 step 5).
///
/// Each record is followed by a [CliTranscriptTail], so a change costs a
/// parse of what was appended. Every row carries the revision it last
/// changed at, so a client naming the revision it holds is sent the new rows
/// and only those old ones that moved (a call answered, a subagent retired).
/// A watched record is stat-ed every [interval] — longer when its reads are
/// costly — and each new revision is told to its watchers as
/// [TranscriptChanged]. At most [maxHeld] unwatched records stay in memory.
class SessionTranscripts {
  SessionTranscripts({
    required this.lookUp,
    this.interval = const Duration(seconds: 1),
    this.tick = const Duration(milliseconds: 250),
    this.searchInterval = const Duration(seconds: 3),
    this.maxHeld = 16,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Where a session's record is, or why there is none.
  final Future<SessionRecordLookup> Function(String sessionId) lookUp;
  final Duration interval;
  final Duration tick;

  /// How often a record not found yet is looked for again.
  final Duration searchInterval;
  final int maxHeld;
  final DateTime Function() _now;

  /// Least recently used first.
  final _held = <String, _Held>{};
  Timer? _timer;
  final String _epoch = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  var _generations = 0;

  /// Every session watched by anyone — for a diagnostic.
  Iterable<String> get watched => [
    for (final held in _held.values)
      if (held.links.isNotEmpty) held.sessionId,
  ];

  Future<TranscriptPage> page(SessionTranscriptRead request) async {
    final held = _hold(request.sessionId);
    await _refresh(held);
    return _pageOf(held, request);
  }

  /// One page of a subagent of [SessionTranscriptSubagent.sessionId]: read
  /// whole, off this isolate, and not held — a row is expanded once, and one
  /// session's delegates came to 1,485 MiB. Refused `invalid` for a path
  /// outside the session's own subagents directory, so the request cannot
  /// read any other file.
  Future<TranscriptPage> subagent(SessionTranscriptSubagent request) async {
    final held = _hold(request.sessionId);
    await _refresh(held);
    final record = held.file;
    final path = p.normalize(request.path);
    if (record == null ||
        p.extension(path) != '.jsonl' ||
        !p.isWithin(subagentsDirectoryFor(record), path)) {
      throw const DataRefused.invalid(
        'that path is not a subagent of this session',
      );
    }
    List<TranscriptMessage> messages;
    try {
      messages = await Isolate.run(() => readSubagentTranscript(path));
    } on Object {
      messages = const [];
    }
    final total = messages.length;
    final from = (request.after ?? 0).clamp(0, total);
    final limit = (request.limit ?? kTranscriptPageMaxMessages).clamp(
      1,
      kTranscriptPageMaxMessages,
    );
    final end = _endAfter(messages, from, limit, _kPageChars);
    return TranscriptPage(
      sessionId: request.sessionId,
      generation: 'subagent',
      revision: 0,
      total: total,
      from: from,
      messages: messages.sublist(from, end),
      path: path,
    );
  }

  /// [link] is told of every revision of [sessionId]'s transcript from now
  /// on. Answers once it has been read as it stands.
  Future<void> watch(TranscriptWatchLink link, String sessionId) async {
    final held = _hold(sessionId);
    held.links.add(link);
    _arm();
    await _refresh(held);
  }

  void unwatch(TranscriptWatchLink link, String sessionId) {
    _held[sessionId]?.links.remove(link);
    _trim();
    _arm();
  }

  void closed(TranscriptWatchLink link) {
    for (final held in _held.values) {
      held.links.remove(link);
    }
    _trim();
    _arm();
  }

  Future<void> close() async {
    _timer?.cancel();
    _timer = null;
    _held.clear();
  }

  _Held _hold(String sessionId) {
    final held = _held.remove(sessionId) ?? _Held(sessionId);
    _held[sessionId] = held;
    _trim();
    return held;
  }

  void _trim() {
    for (final id in _held.keys.toList()) {
      if (_held.length <= maxHeld) return;
      if (_held[id]!.links.isEmpty) _held.remove(id);
    }
  }

  void _arm() {
    if (!_held.values.any((held) => held.links.isNotEmpty)) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer.periodic(tick, (_) => _sweep());
  }

  void _sweep() {
    final now = _now();
    for (final held in _held.values.toList()) {
      if (held.links.isEmpty || held.polling || now.isBefore(held.nextAt)) {
        continue;
      }
      unawaited(_poll(held));
    }
  }

  Future<void> _poll(_Held held) async {
    held.polling = true;
    try {
      await _refresh(held);
    } finally {
      held.polling = false;
      final costly = held.cost * _backoffFactor;
      held.nextAt = _now().add(costly > interval ? costly : interval);
    }
  }

  static const int _backoffFactor = 4;

  /// One read at a time per record; then whoever watches is told of a new
  /// revision, whichever read found it.
  Future<void> _refresh(_Held held) {
    final run = held.lock.then((_) => _read(held));
    held.lock = run.catchError((Object _) {});
    return run.then((_) {
      if (held.revision <= held.toldRevision) return;
      held.toldRevision = held.revision;
      final change = TranscriptChanged(
        sessionId: held.sessionId,
        generation: held.generation,
        revision: held.revision,
        total: held.messages.length,
      );
      for (final link in held.links.toList()) {
        link.tell([change]);
      }
    });
  }

  Future<void> _read(_Held held) async {
    final now = _now();
    if (held.tail == null) {
      final at = held.lookedAt;
      if (at != null && now.difference(at) < searchInterval) return;
      held.lookedAt = now;
      final found = await lookUp(held.sessionId);
      final storePath = found.path;
      final agentId = found.agentId;
      if (storePath == null || agentId == null) {
        return _absent(held, found.absence ?? ChatViewEvidence.notLocated);
      }
      final file = transcriptFileFor(storePath, agentId);
      if (file == null) {
        return _absent(held, ChatViewEvidence.storeUnreadable);
      }
      held
        ..storePath = storePath
        ..file = file
        ..tail = CliTranscriptTail(storePath, agentId);
    }
    final file = held.file!;
    final FileStat stat;
    try {
      stat = await File(file).stat();
    } on Object {
      return;
    }
    if (stat.type == FileSystemEntityType.notFound) {
      final absence = file == held.storePath
          ? ChatViewEvidence.notLocated
          : ChatViewEvidence.transcriptAbsent;
      // Looked for again: a record can be replaced by one at another path.
      held
        ..tail = null
        ..lookedAt = now
        ..stamp = null;
      return _absent(held, absence);
    }
    final stamp = (stat.size, stat.modified);
    if (held.stamp == stamp) return;
    final clock = Stopwatch()..start();
    final List<TranscriptMessage> next;
    try {
      next = await held.tail!.read();
    } on Object {
      return;
    }
    held
      ..cost = clock.elapsed
      ..stamp = stamp;
    _absorb(held, next);
  }

  void _absent(_Held held, ChatViewEvidence absence) {
    if (held.absence == absence && held.generation.isEmpty) return;
    held
      ..absence = absence
      ..generation = ''
      ..messages = const []
      ..changedAt = []
      ..revision += 1;
  }

  void _absorb(_Held held, List<TranscriptMessage> next) {
    final old = held.messages;
    final revision = held.revision + 1;
    if (held.generation.isEmpty || next.length < old.length) {
      held
        ..absence = null
        ..generation = '$_epoch.${++_generations}'
        ..messages = next
        ..changedAt = List.filled(next.length, revision, growable: true)
        ..revision = revision;
      return;
    }
    var moved = false;
    for (var i = 0; i < old.length; i++) {
      if (!sameTranscriptMessage(old[i], next[i])) {
        held.changedAt[i] = revision;
        moved = true;
      }
    }
    for (var i = old.length; i < next.length; i++) {
      held.changedAt.add(revision);
      moved = true;
    }
    held.messages = next;
    if (moved) held.revision = revision;
  }

  TranscriptPage _pageOf(_Held held, SessionTranscriptRead request) {
    TranscriptPage answer(
      int from,
      int end, {
      List<TranscriptUpdate> updates = const [],
      bool reset = false,
    }) => TranscriptPage(
      sessionId: held.sessionId,
      generation: held.generation,
      revision: held.revision,
      total: held.messages.length,
      from: from,
      messages: held.messages.sublist(from, end),
      updates: updates,
      reset: reset,
      absence: held.absence,
      path: held.file,
    );

    if (held.generation.isEmpty) {
      return TranscriptPage(
        sessionId: held.sessionId,
        generation: '',
        revision: held.revision,
        total: 0,
        from: 0,
        messages: const [],
        absence: held.absence ?? ChatViewEvidence.notLocated,
      );
    }
    final messages = held.messages;
    final total = messages.length;
    final limit = (request.limit ?? kTranscriptPageDefaultMessages).clamp(
      1,
      kTranscriptPageMaxMessages,
    );
    final since = request.revision;
    final known =
        request.generation == held.generation &&
        since != null &&
        since <= held.revision;

    final before = request.before;
    if (before != null && known) {
      final end = before.clamp(0, total);
      return answer(_startBefore(messages, end, limit, _kPageChars), end);
    }
    final after = request.after;
    if (after != null && known && after <= total) {
      final updates = <TranscriptUpdate>[];
      var spent = 0;
      for (var i = 0; i < after; i++) {
        if (held.changedAt[i] <= since) continue;
        updates.add(TranscriptUpdate(i, messages[i]));
        spent += _chars(messages[i]);
      }
      if (updates.length <= limit && spent <= _kPageChars) {
        final end = _endAfter(messages, after, limit, _kPageChars - spent);
        return answer(after, end, updates: updates);
      }
    }
    final reset = request.generation != null || after != null || before != null;
    return answer(
      _startBefore(messages, total, limit, _kPageChars),
      total,
      reset: reset,
    );
  }

  /// The most text one page carries: a message holds up to three 64 KiB
  /// fields, and a page must stay well inside the 16 MiB frame.
  static const int _kPageChars = 2 * 1024 * 1024;

  static int _chars(TranscriptMessage message) =>
      message.text.length +
      (message.thinking?.length ?? 0) +
      (message.tool?.output?.length ?? 0) +
      (message.tool?.subject?.length ?? 0) +
      256;

  /// Where a page ending at [end] starts: [limit] rows back, fewer when
  /// [budget] runs out, never none.
  static int _startBefore(
    List<TranscriptMessage> messages,
    int end,
    int limit,
    int budget,
  ) {
    var start = end;
    var spent = 0;
    while (start > 0 && end - start < limit) {
      spent += _chars(messages[start - 1]);
      if (spent > budget && start < end) break;
      start--;
    }
    return start;
  }

  static int _endAfter(
    List<TranscriptMessage> messages,
    int from,
    int limit,
    int budget,
  ) {
    var end = from;
    var spent = 0;
    while (end < messages.length && end - from < limit) {
      spent += _chars(messages[end]);
      if (spent > budget && end > from) break;
      end++;
    }
    return end;
  }
}

class _Held {
  _Held(this.sessionId);

  final String sessionId;
  final links = <TranscriptWatchLink>{};

  CliTranscriptTail? tail;
  String? storePath;
  String? file;
  DateTime? lookedAt;
  (int, DateTime)? stamp;

  /// Empty while nothing has been read, or while [absence] says why not.
  String generation = '';
  ChatViewEvidence? absence;
  int revision = 0;
  int toldRevision = 0;
  List<TranscriptMessage> messages = const [];

  /// The revision each row of [messages] last changed at.
  List<int> changedAt = [];

  Future<void> lock = Future.value();
  bool polling = false;
  Duration cost = Duration.zero;
  DateTime nextAt = DateTime.fromMillisecondsSinceEpoch(0);
}

/// Whether two parses of a row say the same thing. By value: a re-read
/// rebuilds rows that did not change.
bool sameTranscriptMessage(TranscriptMessage a, TranscriptMessage b) =>
    identical(a, b) ||
    (a.role == b.role &&
        a.text == b.text &&
        a.thinking == b.thinking &&
        a.at == b.at &&
        a.pendingToolUseId == b.pendingToolUseId &&
        a.pendingBackgroundAgentId == b.pendingBackgroundAgentId &&
        _sameCompaction(a.compaction, b.compaction) &&
        _sameSubagent(a.subagent, b.subagent) &&
        _sameTool(a.tool, b.tool));

bool _sameCompaction(CompactionBoundary? a, CompactionBoundary? b) =>
    a == null ? b == null : b != null && a.trigger == b.trigger;

bool _sameSubagent(SubagentRef? a, SubagentRef? b) => a == null
    ? b == null
    : b != null &&
          a.toolUseId == b.toolUseId &&
          a.filePath == b.filePath &&
          a.agentType == b.agentType &&
          a.description == b.description &&
          a.spawnDepth == b.spawnDepth &&
          a.model == b.model;

bool _sameTool(ToolActivity? a, ToolActivity? b) => a == null
    ? b == null
    : b != null &&
          (identical(a, b) ||
              (a.name == b.name &&
                  a.subject == b.subject &&
                  a.imagePath == b.imagePath &&
                  a.output == b.output &&
                  a.outputTruncated == b.outputTruncated &&
                  a.isError == b.isError &&
                  a.plan == b.plan));
