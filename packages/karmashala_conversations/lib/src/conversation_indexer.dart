import 'dart:io';

import 'package:karmashala_core/util.dart';
import 'package:agent_cli/read.dart';
import 'conversation_index_dao.dart';
import 'conversation_values.dart';

/// The roles a search may find. The gate is what is read: `text` off these
/// rows, and never `TranscriptMessage.thinking`, whatever CLI it came from.
const Set<String> kIndexedTranscriptRoles = {'user', 'agent'};

/// A transcript's mtime and length, or nulls when it could not be measured.
typedef TranscriptWatermark = ({DateTime? modifiedAt, int? size});

/// Reads a conversation's indexable turns, from [from] when it can resume.
/// `readTranscriptTurns` in production.
typedef TranscriptReader =
    Future<TranscriptTurnsRead> Function(
      String filePath,
      String cli, {
      TranscriptResumePoint? from,
    });

/// Measures a transcript without reading it.
typedef TranscriptStat = Future<TranscriptWatermark> Function(String filePath);

/// Where agent [cli]'s store keeps [conversationId]'s transcript, or null.
typedef TranscriptLocate =
    Future<String?> Function(String cli, String conversationId);

Future<TranscriptTurnsRead> _readIndexable(
  String filePath,
  String cli, {
  TranscriptResumePoint? from,
}) => readTranscriptTurns(
  filePath,
  cli,
  roles: kIndexedTranscriptRoles,
  from: from,
);

/// Keeps the conversation index in step with the transcripts on disk, on the
/// server's triggers: a session row or an imported record that names a
/// conversation is written, or a search asks it to catch up. Nothing polls:
/// the index is as of its last trigger.
///
/// A transcript that grew is read from where the last read stopped, never
/// again from the start; only a file that shrank or changed before that point
/// is read whole — the rule `CliTranscriptTail` follows for the chat view.
class ConversationIndexer {
  ConversationIndexer({
    required this.dao,
    required this.clock,
    TranscriptReader? read,
    TranscriptStat? stat,
  }) : _read = read ?? _readIndexable,
       _stat = stat ?? statTranscript;

  final ConversationIndexDao dao;
  final Clock clock;
  final TranscriptReader _read;
  final TranscriptStat _stat;

  /// Conversations something has asked for and that have not been read yet.
  final Map<String, _Want> _wanted = {};

  /// Transcripts read from the start. The cost claim.
  int parses = 0;

  /// Transcripts read from a resume point: only their appended bytes.
  int appends = 0;

  /// Transcript bytes read, whole and appended together.
  int bytesRead = 0;

  /// Wants the watermark answered without opening the file.
  int skips = 0;

  /// Conversations whose rows were replaced or extended.
  int writes = 0;

  /// Whether [drain] has anything to do. False is the idle workspace.
  bool get hasWork => _wanted.isNotEmpty;

  /// Conversations queued, for diagnostics and tests.
  Iterable<String> get wantedIds => _wanted.keys;

  /// Queues [conversationId] for indexing — a map entry, nothing else until
  /// [drain], which resolves what the caller could not say.
  void want(String conversationId, {String? cli, String? filePath}) {
    if (conversationId.isEmpty) return;
    final existing = _wanted[conversationId];
    _wanted[conversationId] = _Want(
      cli: cli ?? existing?.cli,
      filePath: filePath ?? existing?.filePath,
    );
  }

  /// Indexes everything queued. A want with no path takes the one the index
  /// or the imported history already holds, and only then asks [locate] — the
  /// agent's store, by the conversation's id. Returns how many changed.
  Future<int> drain(TranscriptLocate locate) async {
    if (_wanted.isEmpty) return 0;
    final queued = Map.of(_wanted);
    _wanted.clear();
    var changed = 0;
    for (final entry in queued.entries) {
      var cli = entry.value.cli;
      var path = entry.value.filePath;
      if (cli == null || path == null) {
        final known = dao.knownOf(entry.key);
        cli ??= known.cli;
        path ??= known.filePath;
      }
      if (cli == null) continue;
      if (path == null) {
        try {
          path = await locate(cli, entry.key);
        } on Object {
          // A store we cannot read answers as an empty one. The want is
          // dropped, not kept: the next trigger queues it again.
          path = null;
        }
      }
      if (path == null) continue;
      if (await indexConversation(
        conversationId: entry.key,
        cli: cli,
        filePath: path,
      )) {
        changed++;
      }
      // The store is synchronous on the server's one isolate: hand the event
      // loop back between conversations.
      await Future<void>.delayed(Duration.zero);
    }
    return changed;
  }

  /// Brings one conversation's rows up to date with its transcript, reading
  /// only what it appended when it can. A whole read that finds nothing keeps
  /// the old rows: it cannot be told from format drift.
  Future<bool> indexConversation({
    required String conversationId,
    required String cli,
    required String filePath,
  }) async {
    final state = dao.stateFor(conversationId);
    final row = recordedRowOf(filePath);
    if (row != null) return _indexRecorded(conversationId, cli, row, state);
    // Once read from `session_messages`, always: they are what the chat
    // showed, where a file the agent also keeps may say it differently.
    if (state != null && recordedRowOf(state.filePath) != null) return false;
    final watermark = await _stat(filePath);
    if (state != null &&
        state.filePath == filePath &&
        state.matches(modifiedAt: watermark.modifiedAt, size: watermark.size)) {
      skips++;
      return false;
    }

    // Only the same file: a conversation that moved to another path is a
    // different file, and an offset into one says nothing about the other.
    final from = state != null && state.filePath == filePath
        ? state.resumePoint
        : null;
    TranscriptTurnsRead read;
    try {
      read = await _read(filePath, cli, from: from);
    } on Object {
      // The reader swallows malformed lines itself; this catches the layer
      // below — an unopenable path, e.g. a vanished `\\wsl.localhost`.
      read = TranscriptTurnsRead.nothing;
    }
    bytesRead += read.bytesRead;
    final turns = [
      for (final turn in read.turns)
        ConversationTurn(
          ordinal: turn.ordinal,
          role: turn.role,
          text: turn.text,
          at: turn.at,
        ),
    ];
    final now = clock.nowUtc();

    if (read.appended && from != null && state != null) {
      appends++;
      dao.appendTurns(
        sessionId: conversationId,
        cli: cli,
        filePath: filePath,
        turns: turns,
        fromOrdinal: from.rows,
        heldTurns: state.turns,
        indexedAt: now,
        resumePoint: read.resumePoint!,
        modifiedAt: watermark.modifiedAt,
        size: watermark.size,
      );
      if (turns.isEmpty) return false;
      writes++;
      return true;
    }

    parses++;
    if (turns.isEmpty && (state?.turns ?? 0) > 0) {
      // No resume point either: the rows kept were not read up to it.
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
      resumePoint: read.resumePoint,
    );
    writes++;
    return true;
  }
}

extension on ConversationIndexer {
  /// [conversationId] read whole from session row [rowId]'s messages, unless
  /// its newest revision is the one already read.
  bool _indexRecorded(
    String conversationId,
    String cli,
    String rowId,
    ConversationIndexState? state,
  ) {
    final filePath = recordedConversationPath(rowId);
    final watermark = dao.recordedWatermark(rowId);
    if (state != null &&
        state.filePath == filePath &&
        state.matches(modifiedAt: watermark.modifiedAt, size: watermark.size)) {
      skips++;
      return false;
    }
    parses++;
    dao.replaceTurns(
      sessionId: conversationId,
      cli: cli,
      filePath: filePath,
      turns: dao.recordedTurns(rowId),
      indexedAt: clock.nowUtc(),
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
