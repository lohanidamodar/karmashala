import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import '../../util/sqlite_rows.dart';

/// One Antigravity CLI conversation, as far as its store makes it readable.
///
/// the design noteconcluded that this store was
/// "permanently unreadable" and recorded `AgentStoreFormat.none` on that
/// finding. The finding was drawn from one file — `conversations/<id>.db`,
/// whose payload columns really are opaque protobuf — and generalised to the
/// whole directory. The rest of the directory is plain JSON and plain text, and
/// it carries the identity, the working directory and the name.
///
/// What is read here, and from where:
///
/// | Field | Source | Notes |
/// | --- | --- | --- |
/// | [id] | `conversations/<id>.db` file name | also `trajectory_meta.cascade_id` |
/// | [workspace] | `cache/last_conversations.json` | latest per directory only |
/// | [title] | `annotations/<id>.pbtxt` | what `/rename` wrote |
/// | [preview] | `conversation_summaries.db` | populated late, often absent |
/// | [stepCount] | `steps` row count in the conversation's own file | live |
/// | [modifiedAt] | the conversation file's mtime | always available |
///
/// Message *content* stays unreadable, and that part of the old assessment
/// holds: `steps.step_payload` is a protobuf in an unpublished schema. So there
/// is still no transcript, no chat view and no handoff packet — but there is an
/// id, a directory, a name, a size and a time.
class AntigravityConversation {
  const AntigravityConversation({
    required this.id,
    required this.filePath,
    required this.storeHome,
    this.workspace,
    this.title,
    this.preview = '',
    this.stepCount,
    this.modifiedAt,
    this.hasPresenceFile = false,
  });

  /// The CLI's own conversation id — the `<uuid>` of `conversations/<uuid>.db`,
  /// and the value `agy --conversation` takes.
  final String id;

  /// The conversation file itself, in a form this app can read directly.
  final String filePath;

  /// The `.gemini/antigravity-cli` directory [filePath] lives under.
  final String storeHome;

  /// The directory `agy` was launched in, when the store still records it.
  ///
  /// `cache/last_conversations.json` holds **one entry per directory**, so only
  /// the newest conversation in any directory has a workspace here; an older
  /// one in the same directory has been overwritten and reads as `null`. That
  /// is a property of the CLI's file, not a gap in this reader, and it is why
  /// attribution is written against the directory rather than against this
  /// field.
  final String? workspace;

  /// The name `/rename` gave this conversation, from `annotations/<id>.pbtxt`.
  final String? title;

  /// The CLI's own one-line summary. Written by a background summariser rather
  /// than at the first turn, so a conversation can be hours old and still have
  /// none.
  final String preview;

  /// How many steps the conversation holds, counted live from its own file.
  ///
  /// `null` when the file could not be opened — never `0` for "we did not
  /// look", because a real conversation can genuinely hold no steps.
  final int? stepCount;

  final DateTime? modifiedAt;

  /// Whether `presence/<id>.lock` exists.
  ///
  /// **Not liveness.** The CLI creates the file when it opens a conversation
  /// and leaves it behind on exit, so this says the conversation has been
  /// opened at least once, and nothing about now. Whether a process holds it is
  /// an flock, which is not observable from here.
  final bool hasPresenceFile;

  /// The best label the store honestly supports, or `null` when it supports
  /// none — never a placeholder, so a caller can tell "unnamed" from "named
  /// nothing".
  String? get displayTitle {
    final named = title?.trim();
    if (named != null && named.isNotEmpty) return named;
    final summarised = preview.trim();
    return summarised.isEmpty ? null : summarised;
  }

  @override
  String toString() => 'AntigravityConversation($id)';
}

/// Cache for Antigravity store artifacts so unchanged files are not re-read
/// on every sweep.
class AntigravityStoreCache {
  AntigravityStoreCache();

  static final AntigravityStoreCache shared = AntigravityStoreCache();

  final Map<String, _HistoryCacheEntry> _historyByStore = {};
  final Map<String, _FileCacheEntry<Map<String, String>>> _lastConvsByStore = {};
  final Map<String, _FileCacheEntry<Map<String, AntigravityConversationSummary>>>
      _summariesByStore = {};
  final Map<String, _TitleCacheEntry> _titlesByPath = {};

  void clear() {
    _historyByStore.clear();
    _lastConvsByStore.clear();
    _summariesByStore.clear();
    _titlesByPath.clear();
  }
}

class _HistoryCacheEntry {
  const _HistoryCacheEntry({
    required this.length,
    required this.modified,
    required this.workspaces,
  });

  final int length;
  final DateTime modified;
  final Map<String, String> workspaces;
}

class _FileCacheEntry<T> {
  const _FileCacheEntry({
    required this.length,
    required this.modified,
    required this.data,
  });

  final int length;
  final DateTime modified;
  final T data;
}

class _TitleCacheEntry {
  const _TitleCacheEntry({
    required this.modified,
    required this.title,
  });

  final DateTime modified;
  final String? title;
}

/// Reads the Antigravity CLI's store at `~/.gemini/antigravity-cli`.
///
/// Every source is opened read-only and every failure is swallowed into an
/// absent field: this reads a directory the user's own CLI is writing to, and a
/// status poll that throws because a file was mid-write would be worse than one
/// that says "not recorded".
class AntigravityStoreReader {
  const AntigravityStoreReader({
    this.countSteps = true,
    this.cache,
    this.readRows = noSqliteBinding,
  });

  /// Whether to open each conversation file to count its steps. Off makes the
  /// sweep a directory listing plus two small files.
  final bool countSteps;

  /// Injected cache for testing or scoping; defaults to [AntigravityStoreCache.shared].
  final AntigravityStoreCache? cache;

  /// How to read Antigravity's own SQLite files. Defaults to no binding at all,
  /// so a caller that supplies none gets the same answer a busy database gives
  /// — "not recorded" — rather than this package pulling in a native library
  /// (see [SqliteRowReader]).
  final SqliteRowReader readRows;

  AntigravityStoreCache get _effectiveCache =>
      cache ?? AntigravityStoreCache.shared;

  /// Every conversation in [storeHome], newest first.
  Future<List<AntigravityConversation>> read(String storeHome) async {
    final dir = Directory(p.join(storeHome, 'conversations'));
    if (!await dir.exists()) return const [];

    final workspaces = await readWorkspacesByConversation(storeHome);
    final summaries = await readSummaries(storeHome);
    final titles = await readTitles(storeHome);
    final presenceIds = await readPresenceIds(storeHome);

    final conversationsById = <String, AntigravityConversation>{};
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      final isDb = name.endsWith('.db');
      final isPb = name.endsWith('.pb');
      if (!isDb && !isPb) continue;
      final id = isDb
          ? name.substring(0, name.length - '.db'.length)
          : name.substring(0, name.length - '.pb'.length);
      if (id.isEmpty) continue;

      final existing = conversationsById[id];
      if (existing != null && existing.filePath.endsWith('.db') && !isDb) {
        continue;
      }

      DateTime? modified;
      try {
        modified = (await entity.stat()).modified;
      } on FileSystemException {
        // Left null: the conversation is still real, we just cannot time it.
      }

      final summary = summaries[id];
      conversationsById[id] = AntigravityConversation(
        id: id,
        filePath: entity.path,
        storeHome: storeHome,
        workspace: workspaces[id],
        title: titles[id],
        preview: summary?.preview ?? '',
        stepCount: countSteps && isDb
            ? await readStepCount(entity.path) ?? summary?.stepCount
            : summary?.stepCount,
        modifiedAt: modified ?? existing?.modifiedAt,
        hasPresenceFile: presenceIds.contains(id),
      );
    }

    final conversations = conversationsById.values.toList();
    conversations.sort((a, b) {
      final at = a.modifiedAt, bt = b.modifiedAt;
      if (at == null && bt == null) return a.id.compareTo(b.id);
      if (at == null) return 1;
      if (bt == null) return -1;
      return bt.compareTo(at);
    });
    return conversations;
  }

  /// `cache/last_conversations.json`: the directory `agy` was launched in → the
  /// conversation it last used there.
  ///
  /// This is the file `agy -c` itself reads (`store.Manager.GetLastConversation`
  /// in the 1.1.22 binary, written by `PersistLastConversation`), which is what
  /// makes it two things at once: the soundest way to attribute a conversation
  /// to a session we started in a known directory, and the exact definition of
  /// what `--continue` would continue.
  ///
  /// Returns an empty map when the file is missing or is not a JSON object of
  /// strings — never a partial map built from a half-decoded file.
  Future<Map<String, String>> readLastConversations(String storeHome) async {
    final file = File(p.join(storeHome, 'cache', 'last_conversations.json'));
    try {
      if (!await file.exists()) return const {};
      final stat = await file.stat();
      final cached = _effectiveCache._lastConvsByStore[storeHome];
      if (cached != null &&
          cached.length == stat.size &&
          cached.modified == stat.modified) {
        return cached.data;
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return const {};
      final result = {
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: entry.value as String,
      };
      _effectiveCache._lastConvsByStore[storeHome] = _FileCacheEntry(
        length: stat.size,
        modified: stat.modified,
        data: result,
      );
      return result;
    } on FileSystemException {
      return const {};
    } on FormatException {
      return const {};
    }
  }

  /// [readLastConversations] inverted: conversation id → the directory it was
  /// last used in.
  ///
  /// One directory can only name one conversation, but two directories could
  /// name the same conversation — `--add-dir` and a resume from elsewhere both
  /// do it — so a conversation claimed by more than one directory is left out
  /// rather than arbitrarily assigned one of them.
  /// `history.jsonl`: extracts workspace directories keyed by conversation id.
  Future<Map<String, String>> readHistoryWorkspaces(String storeHome) async {
    final file = File(p.join(storeHome, 'history.jsonl'));
    try {
      if (!await file.exists()) return const {};
      final stat = await file.stat();
      final cached = _effectiveCache._historyByStore[storeHome];
      if (cached != null &&
          cached.length == stat.size &&
          cached.modified == stat.modified) {
        return cached.workspaces;
      }
      final lines = await file.readAsLines();
      final byId = <String, String>{};
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || !trimmed.startsWith('{')) continue;
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is Map<String, dynamic>) {
            final cid = decoded['conversationId'];
            final ws = decoded['workspace'];
            if (cid is String && ws is String && cid.isNotEmpty && ws.isNotEmpty) {
              byId[cid] = ws;
            }
          }
        } on FormatException {
          continue;
        }
      }
      _effectiveCache._historyByStore[storeHome] = _HistoryCacheEntry(
        length: stat.size,
        modified: stat.modified,
        workspaces: byId,
      );
      return byId;
    } on FileSystemException {
      return const {};
    }
  }

  /// [readLastConversations] inverted: conversation id → the directory it was
  /// last used in, supplemented by [readHistoryWorkspaces].
  ///
  /// One directory can only name one conversation, but two directories could
  /// name the same conversation — `--add-dir` and a resume from elsewhere both
  /// do it — so a conversation claimed by more than one directory is left out
  /// rather than arbitrarily assigned one of them.
  Future<Map<String, String>> readWorkspacesByConversation(
    String storeHome,
  ) async {
    final historyWorkspaces = await readHistoryWorkspaces(storeHome);
    final byDirectory = await readLastConversations(storeHome);
    final byConversation = <String, String>{...historyWorkspaces};
    final ambiguous = <String>{};
    for (final entry in byDirectory.entries) {
      if (byConversation.containsKey(entry.value) &&
          byConversation[entry.value] != entry.key &&
          !historyWorkspaces.containsKey(entry.value)) {
        ambiguous.add(entry.value);
        continue;
      }
      byConversation[entry.value] = entry.key;
    }
    for (final id in ambiguous) {
      byConversation.remove(id);
    }
    return byConversation;
  }

  /// Reads all conversation titles in [storeHome], keyed by conversation id.
  Future<Map<String, String>> readTitles(String storeHome) async {
    final dir = Directory(p.join(storeHome, 'annotations'));
    try {
      if (!await dir.exists()) return const {};
      final titles = <String, String>{};
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (!name.endsWith('.pbtxt')) continue;
        final id = name.substring(0, name.length - '.pbtxt'.length);
        if (id.isEmpty) continue;
        try {
          final stat = await entity.stat();
          final cached = _effectiveCache._titlesByPath[entity.path];
          if (cached != null && cached.modified == stat.modified) {
            if (cached.title != null) titles[id] = cached.title!;
            continue;
          }
          final content = await entity.readAsString();
          final title = _titleIn(content);
          _effectiveCache._titlesByPath[entity.path] = _TitleCacheEntry(
            modified: stat.modified,
            title: title,
          );
          if (title != null) titles[id] = title;
        } on FileSystemException {
          // Ignored
        }
      }
      return titles;
    } on FileSystemException {
      return const {};
    }
  }

  /// Every conversation id in [storeHome] that has a presence file.
  Future<Set<String>> readPresenceIds(String storeHome) async {
    final dir = Directory(p.join(storeHome, 'presence'));
    try {
      if (!await dir.exists()) return const {};
      final ids = <String>{};
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (!name.endsWith('.lock')) continue;
        final id = name.substring(0, name.length - '.lock'.length);
        if (id.isNotEmpty) ids.add(id);
      }
      return ids;
    } on FileSystemException {
      return const {};
    }
  }

  /// The name `/rename` gave conversation [id], or `null` when it has none.
  ///
  /// `annotations/<id>.pbtxt` is protobuf text format holding a single field:
  ///
  ///     title:"test me now"
  ///
  /// Written the moment the user renames, so unlike the summary caches it is
  /// never stale — it is the one part of this store that reflects an edit
  /// immediately.
  Future<String?> readTitle(String storeHome, String id) async {
    final file = File(p.join(storeHome, 'annotations', '$id.pbtxt'));
    try {
      if (!await file.exists()) return null;
      final stat = await file.stat();
      final cached = _effectiveCache._titlesByPath[file.path];
      if (cached != null && cached.modified == stat.modified) {
        return cached.title;
      }
      final title = _titleIn(await file.readAsString());
      _effectiveCache._titlesByPath[file.path] = _TitleCacheEntry(
        modified: stat.modified,
        title: title,
      );
      return title;
    } on FileSystemException {
      return null;
    }
  }

  /// How many steps `conversations/<id>.db` holds.
  ///
  /// Opened read-only, and `null` on any failure — the CLI may hold the file,
  /// and a busy database is "not recorded", not an error to propagate.
  Future<int?> readStepCount(String conversationFile) async {
    if (!conversationFile.endsWith('.db')) return null;
    final rows = await readRows(
      conversationFile,
      'select count(*) as n from steps',
    );
    if (rows == null || rows.isEmpty) return null;
    final n = rows.first['n'];
    return n is int ? n : null;
  }

  /// `conversation_summaries.db`, keyed by conversation id.
  ///
  /// **A hint, never the index.** On a live installation this table held one
  /// row while three conversations existed, because rows are written by a
  /// background summariser rather than when a conversation starts. So a missing
  /// row means nothing at all, and building detection on this table alone would
  /// hide most of the user's conversations.
  Future<Map<String, AntigravityConversationSummary>> readSummaries(
    String storeHome,
  ) async {
    final path = p.join(storeHome, 'conversation_summaries.db');
    final file = File(path);
    if (!await file.exists()) return const {};
    final stat = await file.stat();
    final cached = _effectiveCache._summariesByStore[storeHome];
    if (cached != null &&
        cached.length == stat.size &&
        cached.modified == stat.modified) {
      return cached.data;
    }
    final rows = await readRows(
      path,
      'select conversation_id, title, preview, step_count, workspace_uris '
      'from conversation_summaries',
    );
    if (rows == null) return const {};
    final result = {
        for (final row in rows)
        if (row['conversation_id'] is String)
          row['conversation_id'] as String: AntigravityConversationSummary(
            title: _text(row['title']),
            preview: _text(row['preview']),
            stepCount: row['step_count'] is int
                ? row['step_count'] as int
                : null,
            workspaceUris: _text(row['workspace_uris']),
          ),
    };
    _effectiveCache._summariesByStore[storeHome] = _FileCacheEntry(
      length: stat.size,
      modified: stat.modified,
      data: result,
    );
    return result;
  }
}

/// One row of `conversation_summaries.db`.
class AntigravityConversationSummary {
  const AntigravityConversationSummary({
    this.title = '',
    this.preview = '',
    this.stepCount,
    this.workspaceUris = '',
  });

  final String title;
  final String preview;
  final int? stepCount;

  /// Empty in every row written on the installation this was read from, which
  /// is why it is carried but not relied on.
  final String workspaceUris;
}

String _text(Object? value) => value is String ? value : '';

/// The `title` field of a protobuf text-format record, unescaped.
String? _titleIn(String source) {
  final match = RegExp(r'title\s*:\s*"((?:[^"\\]|\\.)*)"').firstMatch(source);
  if (match == null) return null;
  final raw = match.group(1)!;
  final unescaped = raw.replaceAllMapped(RegExp(r'\\(.)'), (m) {
    return switch (m.group(1)) {
      'n' => '\n',
      't' => '\t',
      'r' => '\r',
      final other => other ?? '',
    };
  });
  return unescaped.trim().isEmpty ? null : unescaped;
}
