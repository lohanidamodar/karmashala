import 'dart:io';

import 'package:karmashala_core/util.dart';
import 'package:agent_cli/read.dart';
import '../data/conversation_index_dao.dart';

/// The roles a search may find. The gate is what is read: `text` off these
/// rows, and never `TranscriptMessage.thinking`, whatever CLI it came from.
const Set<String> kIndexedTranscriptRoles = {'user', 'agent'};

/// A transcript's mtime and length, or nulls when it could not be measured.
typedef TranscriptWatermark = ({DateTime? modifiedAt, int? size});

/// Reads a conversation's transcript. `readCliTranscript` in production.
typedef TranscriptReader =
    Future<List<TranscriptMessage>> Function(String filePath, String cli);

/// Measures a transcript without reading it.
typedef TranscriptStat = Future<TranscriptWatermark> Function(String filePath);

/// Keeps the conversation index in step with the transcripts on disk, on the
/// app's existing triggers. Nothing polls: the index is as of its last trigger.
class ConversationIndexer {
  ConversationIndexer({
    required this.dao,
    required this.clock,
    TranscriptReader? read,
    TranscriptStat? stat,
  }) : _read = read ?? readCliTranscript,
       _stat = stat ?? statTranscript;

  final ConversationIndexDao dao;
  final Clock clock;
  final TranscriptReader _read;
  final TranscriptStat _stat;

  /// Conversations something has asked for and that have not been read yet.
  final Map<String, _Want> _wanted = {};

  /// Transcripts actually parsed. The cost claim.
  int parses = 0;

  /// Wants the watermark answered without opening the file.
  int skips = 0;

  /// Conversations whose rows were replaced.
  int writes = 0;

  /// Whether [drain] has anything to do. False is the idle workspace.
  bool get hasWork => _wanted.isNotEmpty;

  /// Conversations queued, for diagnostics and tests.
  Iterable<String> get wantedIds => _wanted.keys;

  /// Queues [conversationId] for indexing — a map entry, nothing else until
  /// [drain], which resolves a missing [filePath] against the slot's store scan.
  void want(String conversationId, {String? cli, String? filePath}) {
    if (conversationId.isEmpty) return;
    final existing = _wanted[conversationId];
    _wanted[conversationId] = _Want(
      cli: cli ?? existing?.cli,
      filePath: filePath ?? existing?.filePath,
    );
  }

  /// Indexes everything queued, resolving unknown paths through [scan]. Returns
  /// how many changed; [scan] runs only for a queued conversation with no path.
  Future<int> drain(Future<List<DetectedSession>> Function() scan) async {
    if (_wanted.isEmpty) return 0;
    final queued = Map.of(_wanted);
    _wanted.clear();
    final unresolved = queued.entries
        .where((entry) => entry.value.filePath == null)
        .map((entry) => entry.key)
        .toSet();
    var found = <String, DetectedSession>{};
    if (unresolved.isNotEmpty) {
      try {
        found = {
          for (final session in await scan()) session.sessionId: session,
        };
      } on Object {
        // A store we cannot read answers as an empty one. Wants are dropped,
        // not kept — keeping them makes every later slot re-scan for ever.
        return 0;
      }
    }
    var changed = 0;
    for (final entry in queued.entries) {
      final want = entry.value;
      final detected = found[entry.key];
      final path = want.filePath ?? detected?.filePath;
      final cli = want.cli ?? detected?.cli;
      if (path == null || cli == null) continue;
      if (await indexConversation(
        conversationId: entry.key,
        cli: cli,
        filePath: path,
      )) {
        changed++;
      }
    }
    return changed;
  }

  /// Reads one conversation's transcript into the index if it has moved. A
  /// parse that finds nothing keeps the old rows: it cannot be told from drift.
  Future<bool> indexConversation({
    required String conversationId,
    required String cli,
    required String filePath,
  }) async {
    final state = dao.stateFor(conversationId);
    final watermark = await _stat(filePath);
    if (state != null &&
        state.filePath == filePath &&
        state.matches(modifiedAt: watermark.modifiedAt, size: watermark.size)) {
      skips++;
      return false;
    }

    List<TranscriptMessage> messages;
    try {
      messages = await _read(filePath, cli);
    } on Object {
      // `readCliTranscript` swallows malformed lines itself; this catches the
      // layer below — an unopenable path, e.g. a vanished `\\wsl.localhost`.
      messages = const [];
    }
    parses++;

    final turns = <ConversationTurn>[];
    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      if (!kIndexedTranscriptRoles.contains(message.role)) continue;
      if (message.text.isEmpty) continue;
      // The ordinal is the position as parsed, tool rows counted, so it lines
      // up with the chat view. A hint, never a key.
      turns.add(
        ConversationTurn(ordinal: i, role: message.role, text: message.text),
      );
    }

    final now = clock.nowUtc();
    if (turns.isEmpty && (state?.turns ?? 0) > 0) {
      dao.keepTurns(
        sessionId: conversationId,
        cli: cli,
        filePath: filePath,
        turns: state!.turns,
        indexedAt: now,
        modifiedAt: watermark.modifiedAt,
        size: watermark.size,
      );
      return false;
    }
    dao.replaceTurns(
      sessionId: conversationId,
      cli: cli,
      filePath: filePath,
      turns: turns,
      indexedAt: now,
      modifiedAt: watermark.modifiedAt,
      size: watermark.size,
    );
    writes++;
    return true;
  }
}

/// A queued conversation: whatever the caller could tell us about it.
class _Want {
  const _Want({this.cli, this.filePath});

  final String? cli;
  final String? filePath;
}

/// The production [TranscriptStat]. Async `stat()`, not the synchronous pair,
/// and nulls rather than a throw: unreachable cannot be told from absent.
Future<TranscriptWatermark> statTranscript(String filePath) async {
  try {
    final stat = await File(filePath).stat();
    if (stat.type == FileSystemEntityType.notFound) {
      return (modifiedAt: null, size: null);
    }
    return (modifiedAt: stat.modified.toUtc(), size: stat.size);
  } on Object {
    return (modifiedAt: null, size: null);
  }
}
