import 'dart:io';

import '../../../core/util/clock.dart';
import '../data/cli_transcript_reader.dart';
import '../data/conversation_index_dao.dart';
import '../domain/detected_session.dart';

/// The roles a search may find.
///
/// **`tool` is excluded, and that is the design rather than an omission.** A
/// transcript's tool rows carry every command run and every file read back, so
/// indexing them would make a filename search return every run that *touched*
/// the file instead of the messages that *discussed* it — which is grep, and
/// grep already exists. Thinking blocks are out for the same reason: they are
/// the model working, not anybody's decision. `readCliTranscript` already drops
/// them (nothing in it ever fills `TranscriptMessage.thinking`), so this is the
/// second of two gates rather than the only one.
const Set<String> kIndexedTranscriptRoles = {'user', 'agent'};

/// A transcript's mtime and length, or nulls when it could not be measured.
typedef TranscriptWatermark = ({DateTime? modifiedAt, int? size});

/// Reads a conversation's transcript. `readCliTranscript` in production.
typedef TranscriptReader =
    Future<List<TranscriptMessage>> Function(String filePath, String cli);

/// Measures a transcript without reading it.
typedef TranscriptStat = Future<TranscriptWatermark> Function(String filePath);

/// Keeps the conversation index in step with the transcripts on disk, **on the
/// triggers the app already fires**.
///
/// ## Nothing here polls
///
/// There is no timer, no watcher and no sweep. Work arrives one of three ways:
///
/// 1. `SessionAdoptionService` adopts a session — a conversation has just
///    entered the workspace, once per conversation;
/// 2. `SessionTitleSyncService` renames one — the CLI wrote to that
///    conversation's store, which is the app's existing evidence that its
///    transcript moved;
/// 3. the one-off backfill, over the history the app already has paths for.
///
/// Each of those calls [want], which costs a map entry. [drain] then does the
/// disk work on the store slot that is already open, and **returns before
/// touching anything when nothing is wanted** — so an idle workspace indexes
/// zero times, which is what `conversation_indexer_test.dart` asserts.
///
/// The consequence, stated rather than hidden: **the index is as of its last
/// trigger.** A live conversation's newest turns are not searchable until
/// something triggers again, and every hit carries `indexedAt` so the surface
/// can say how old the reading is (CLAUDE.md §19). Making it live would need
/// either a poll or a full-store scan on a cadence, and this app's measured
/// problem is a heap that doubled over five hours — a question asked
/// occasionally must not become a cost paid continuously.
///
/// ## What a transcript that stops parsing does
///
/// Claude Code's transcript format is internal and changes between versions,
/// and we parse it. `readCliTranscript` is best-effort by design: it skips
/// malformed lines, returns what parsed, and yields an empty list for a file it
/// cannot open at all. So a format drift shows up here as **fewer rows, never
/// an exception and never a half-written index**:
///
/// * fewer visible turns parse → fewer rows are written, in one transaction,
///   so the index either wholly moves to the new reading or wholly keeps the
///   old;
/// * *nothing* parses, and the conversation already had rows → the old rows
///   are **kept** and only the watermark advances. A parse that produced none
///   cannot be told from a transcript we no longer understand, and yesterday's
///   rows are a better answer than none;
/// * the file is gone or unreachable → identical to the case above, because a
///   stat that cannot complete and a parse that finds nothing are the same
///   evidence. §20's rule: the stored path is state, whether it resolves is a
///   measurement, and a conversation does not leave the index because a
///   measurement failed today.
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

  /// Queues [conversationId] for indexing.
  ///
  /// Free: a map entry, and nothing else until [drain]. [filePath] is supplied
  /// by callers that already hold one — the backfill reads
  /// `imported_sessions.file_path` — and omitted by the triggers, which know
  /// a conversation id and no path; [drain] resolves those against the store
  /// scan the slot has already paid for.
  void want(String conversationId, {String? cli, String? filePath}) {
    if (conversationId.isEmpty) return;
    final existing = _wanted[conversationId];
    _wanted[conversationId] = _Want(
      cli: cli ?? existing?.cli,
      filePath: filePath ?? existing?.filePath,
    );
  }

  /// Indexes everything queued, resolving unknown paths through [scan].
  ///
  /// Returns the number of conversations whose rows changed. **[scan] is called
  /// only when a queued conversation has no path of its own**, and not at all
  /// when nothing is queued, so this cannot be the thing that buys a store
  /// walk.
  Future<int> drain(
    Future<List<DetectedSession>> Function() scan,
  ) async {
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
        // A store we cannot read is the same answer as one with nothing in it.
        // The wants are dropped rather than kept: keeping them would make every
        // later slot re-scan for a conversation the store may never name, which
        // is the continuous cost this whole design refuses. A real trigger will
        // queue it again.
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

  /// Reads one conversation's transcript into the index, if it has moved.
  ///
  /// Returns whether the indexed rows changed. Costs **one SELECT and one
  /// stat** for a transcript whose watermark still matches, and reads nothing.
  Future<bool> indexConversation({
    required String conversationId,
    required String cli,
    required String filePath,
  }) async {
    final state = dao.stateFor(conversationId);
    final watermark = await _stat(filePath);
    if (state != null &&
        state.filePath == filePath &&
        state.matches(
          modifiedAt: watermark.modifiedAt,
          size: watermark.size,
        )) {
      skips++;
      return false;
    }

    List<TranscriptMessage> messages;
    try {
      messages = await _read(filePath, cli);
    } on Object {
      // `readCliTranscript` swallows a malformed line and a truncated file
      // itself; this catches the layer below it — a path that cannot be
      // opened at all, which on this machine includes a `\\wsl.localhost`
      // share that has gone away mid-read. Same answer as an empty parse.
      messages = const [];
    }
    parses++;

    final turns = <ConversationTurn>[];
    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      if (!kIndexedTranscriptRoles.contains(message.role)) continue;
      if (message.text.isEmpty) continue;
      // The ordinal is the position in the transcript *as parsed*, tool rows
      // counted, so it lines up with what the chat view renders. It is a hint,
      // never a key — see `ConversationTurn.ordinal`.
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

/// The production [TranscriptStat].
///
/// `stat()` rather than `existsSync()` + `lengthSync()` for the reason
/// `sessionChatTranscriptProvider` gives: these paths can live on a
/// `\\wsl.localhost` share where the synchronous pair measures 1.19 ms against
/// 0.07 ms locally, and the asynchronous form runs on `dart:io`'s thread pool.
///
/// A file that is absent, or behind a reparse point Windows refuses to
/// traverse, answers nulls rather than throwing — §20's measured finding is
/// that an exception cannot tell an unreachable file from an absent one, and
/// neither can be told from a transcript that has not been written yet.
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
