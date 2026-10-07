import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'package:agent_cli/descriptors.dart'
    show
        ActiveModelReading,
        AgentStoreActiveModel,
        AgentQuestionSet,
        AgentRegistry,
        AgentRewindPoints,
        AgentStats,
        AgentStoreServerClient,
        LifetimeStatsReader,
        OwnRewindPoints,
        SessionStatsReader,
        StoreServerFileChange,
        StoreServerFileChanges,
        TranscriptFileEdits,
        openQuestionIn;
import 'package:agent_cli/process.dart'
    show CommandRequest, CommandRunnerFactory;
import 'package:agent_cli/read.dart'
    show
        FileEditRecord,
        SqliteRowReader,
        noSqliteBinding,
        subagentsDirectoryFor,
        transcriptFileFor;
import 'package:agent_cli/usage.dart'
    show LifetimeStats, LifetimeStatsUnavailable, SessionStats;
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host_protocol/protocol.dart' show kHostVersion;
import 'package:karmashala_session/delivery.dart' show SessionRecordGap;
import 'package:karmashala_session_engine/store.dart'
    show SessionDao, SessionMessageDao, SessionUsageDao;

import 'acp_session_stats.dart';
import 'session_records.dart';
import 'session_subagents.dart' show SubagentTokens;

/// **The readers of a session's raw record lines, run here for any client**
/// (Stage 0 step 7): its agent's rewind points, the files it changed and the
/// question it has open; and its counts (step 9). Each runs the agent adapter's own code over the
/// record [lookUp] finds, as the app ran it over its own disk.
class SessionRecordReadings {
  SessionRecordReadings({
    required this.lookUp,
    required this.registry,
    required this.sessions,
    required this.rows,
    required this.runners,
    this.storeHome,
    this.readRows = noSqliteBinding,
    this.lifetimeFresh = const Duration(seconds: 30),
    this.messages,
    this.usage,
    this.speaksAcp,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Whether session [String]'s agent is spoken to over ACP, by the registry
  /// as it is now; null asks [registry], which knows the shipped agents alone.
  final bool Function(String sessionId)? speaksAcp;

  final Future<SessionRecordLookup> Function(String sessionId) lookUp;
  final AgentRegistry registry;
  final SessionDao sessions;
  final CheckoutRows rows;
  final CommandRunnerFactory runners;

  /// The conversation and usage this server kept of each ACP session, which
  /// answer its counts (`adapter.acp != null`); null answers no counts.
  final SessionMessageDao? messages;
  final SessionUsageDao? usage;

  /// Agent `agentId`'s store home in environment `environmentId`, else in
  /// any environment that has one; null answers no lifetime totals.
  final Future<String?> Function(String agentId, String? environmentId)?
  storeHome;

  /// This server's SQLite binding, for lifetime totals kept in a database.
  final SqliteRowReader readRows;

  /// How long one reading of an agent's lifetime totals answers: they scan
  /// its whole store home.
  final Duration lifetimeFresh;
  final DateTime Function() _now;

  /// One store server per (environment, agent), opened on first use.
  final _storeServers = <(String, String), AgentStoreServerClient>{};

  /// One reader per agent: each keeps its own cache per record, so a second
  /// read of an unchanged record costs a `stat`.
  final _sessionReaders = <String, SessionStatsReader>{};
  final _lifetimeReaders = <String, LifetimeStatsReader>{};
  final _lifetimes =
      <
        (String, String?),
        ({DateTime at, LifetimeStats? stats, LifetimeStatsUnavailable? gap})
      >{};

  /// Each session's counts (`sessions.stats`, Stage 0 step 9), read as the
  /// app read them from its own disk: the adapter's `SessionStatsReader`
  /// over the record [lookUp] finds.
  Future<SessionStatsBatch> stats(SessionStatsRead request) async {
    final ids = request.sessionIds.toSet();
    if (ids.length > kSessionStatsBatchMax) {
      throw DataRefused.invalid(
        '${SessionStatsRead.name}: at most $kSessionStatsBatchMax sessions '
        'at once',
      );
    }
    return SessionStatsBatch({
      for (final id in ids) id: await _statsOf(id, lifetime: request.lifetime),
    });
  }

  Future<SessionStatsReading> _statsOf(
    String sessionId, {
    required bool lifetime,
  }) async {
    final found = await lookUp(sessionId);
    final agentId = found.agentId;
    final row = sessions.getById(sessionId);
    if (agentId == null && row == null) {
      return SessionStatsReading(
        gap: SessionStatsGap.unknownSession,
        lifetimeGap: lifetime
            ? LifetimeStatsUnavailable.agentKeepsNoAggregate
            : null,
      );
    }
    final adapter = agentId == null ? null : registry.adapterFor(agentId);
    final stats = adapter?.stats;
    final (LifetimeStats?, LifetimeStatsUnavailable?) books = lifetime
        ? await _lifetimeOf(
            agentId,
            stats,
            row?.workingDirectory?.environmentId,
          )
        : (null, null);
    SessionStatsReading gap(SessionStatsGap why) => SessionStatsReading(
      gap: why,
      lifetime: books.$1,
      lifetimeGap: books.$2,
    );
    // An agent spoken to over ACP keeps no store of its own here: its rows
    // and its reported usage are this server's.
    final acp = speaksAcp?.call(sessionId) ?? adapter?.acp != null;
    if (acp && row != null) {
      final rows = messages;
      if (rows == null) return gap(SessionStatsGap.agentKeepsNoCounts);
      return SessionStatsReading(
        stats: acpSessionStats(
          rows: rows.listAfter(sessionId),
          usage: usage?.getBySession(sessionId),
        ),
        lifetime: books.$1,
        lifetimeGap: books.$2,
      );
    }
    if (agentId == null || stats == null) {
      return gap(SessionStatsGap.agentKeepsNoCounts);
    }
    final path = found.path;
    if (path == null) return gap(SessionStatsGap.recordNotFound);
    final SessionStats? counted;
    try {
      counted = await _sessionReaders
          .putIfAbsent(agentId, stats.sessionStatsReader)
          .readSessionStats(path);
    } on Object {
      return gap(SessionStatsGap.recordNotFound);
    }
    if (counted == null) return gap(SessionStatsGap.recordNotFound);
    return SessionStatsReading(
      stats: counted,
      lifetime: books.$1,
      lifetimeGap: books.$2,
    );
  }

  Future<(LifetimeStats?, LifetimeStatsUnavailable?)> _lifetimeOf(
    String? agentId,
    AgentStats? stats,
    String? environmentId,
  ) async {
    if (agentId == null || stats == null) {
      return (null, LifetimeStatsUnavailable.agentKeepsNoAggregate);
    }
    final key = (agentId, environmentId);
    final held = _lifetimes[key];
    if (held != null && _now().difference(held.at) < lifetimeFresh) {
      return (held.stats, held.gap);
    }
    LifetimeStats? read;
    try {
      final home = await storeHome?.call(agentId, environmentId);
      read = home == null
          ? null
          : await _lifetimeReaders
                .putIfAbsent(
                  agentId,
                  () => stats.lifetimeReader(readRows: readRows),
                )
                .read(home);
    } on Object {
      read = null;
    }
    final gap = read == null ? LifetimeStatsUnavailable.sourceNotFound : null;
    _lifetimes[key] = (at: _now(), stats: read, gap: gap);
    return (read, gap);
  }

  /// Every token bucket session [sessionId]'s record counts, added up.
  Future<SubagentTokens> tokensOf(String sessionId) async {
    final total = (await _statsOf(
      sessionId,
      lifetime: false,
    )).stats?.tokens.total;
    return (
      total: total,
      gap: total == null ? SubagentTokensGap.notRecorded : null,
    );
  }

  /// The tokens of the subagent of [sessionId] recorded at [path], counted
  /// by its parent agent's own reader. A record over [maxBytes] is not read
  /// on a request: one session's delegates came to 1,485 MiB.
  Future<SubagentTokens> subagentTokensOf(
    String sessionId,
    String path, {
    int maxBytes = 16 * 1024 * 1024,
  }) async {
    const SubagentTokens unread = (
      total: null,
      gap: SubagentTokensGap.notRecorded,
    );
    final found = await lookUp(sessionId);
    final agentId = found.agentId;
    final storePath = found.path;
    if (agentId == null || storePath == null) return unread;
    final record = transcriptFileFor(storePath, agentId) ?? storePath;
    final file = p.normalize(path);
    if (!p.isWithin(subagentsDirectoryFor(record), file)) return unread;
    final stats = registry.adapterFor(agentId)?.stats;
    if (stats == null) return unread;
    try {
      if (await File(file).length() > maxBytes) {
        return (total: null, gap: SubagentTokensGap.tooLarge);
      }
      final counted = await _sessionReaders
          .putIfAbsent(agentId, stats.sessionStatsReader)
          .readSessionStats(file);
      final total = counted?.tokens.total;
      return total == null ? unread : (total: total, gap: null);
    } on Object {
      return unread;
    }
  }

  Future<AgentRewindPoints?> rewindPoints(String sessionId) async {
    final found = await lookUp(sessionId);
    final path = found.path;
    final agentId = found.agentId;
    if (path == null || agentId == null) return null;
    final rewind = registry.adapterFor(agentId)?.rewind;
    if (rewind is! OwnRewindPoints) return null;
    final marker = rewind.lineMarker;
    final parse = rewind.parse;
    try {
      return await Isolate.run(() async {
        final lines = await File(path)
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .where((line) => line.contains(marker))
            .toList();
        return parse(lines);
      });
    } on FileSystemException {
      return null;
    }
  }

  Future<AgentFileChangesReading> changedFiles(String sessionId) async {
    final found = await lookUp(sessionId);
    final agentId = found.agentId;
    final record = agentId == null
        ? null
        : registry.adapterFor(agentId)?.fileChanges;
    switch (record) {
      case null:
        return const AgentFileChangesReading(
          gap: SessionRecordGap.agentKeepsNoRecord,
        );
      case StoreServerFileChanges():
        return _fromStoreServer(sessionId, agentId!);
      case TranscriptFileEdits(:final editsOnLine):
        final path = found.path;
        if (path == null) {
          final row = sessions.getById(sessionId);
          final conversation = row?.externalSessionId ?? '';
          return conversation.isEmpty
              ? const AgentFileChangesReading(
                  gap: SessionRecordGap.noConversationYet,
                )
              : const AgentFileChangesReading(
                  gap: SessionRecordGap.recordUnreadable,
                  detail:
                      'no transcript for this conversation in any store the '
                      'server can read',
                );
        }
        try {
          return AgentFileChangesReading(
            changes: await Isolate.run(() => _editsIn(path, editsOnLine)),
          );
        } on Object catch (error) {
          return AgentFileChangesReading(
            gap: SessionRecordGap.recordUnreadable,
            detail: '$error',
          );
        }
    }
  }

  Future<AgentQuestionSet?> openQuestion(String sessionId) async {
    final found = await lookUp(sessionId);
    final path = found.path;
    final agentId = found.agentId;
    if (path == null || agentId == null) return null;
    final support = registry.byId(agentId)?.questions;
    if (support == null) return null;
    try {
      return openQuestionIn(await _tail(File(path)), support);
    } on FileSystemException {
      return null;
    }
  }

  /// The newest model [sessionId]'s record names, by its agent's own reader;
  /// null when it names none in its last few megabytes or cannot be read.
  Future<ActiveModelReading?> activeModel(String sessionId) async {
    final found = await lookUp(sessionId);
    final path = found.path;
    final agentId = found.agentId;
    if (path == null || agentId == null) return null;
    final reader = registry.adapterFor(agentId)?.activeModel;
    if (reader == null) return null;
    if (reader case final AgentStoreActiveModel store) {
      try {
        return await store.latestInStore(path, readRows);
      } on Object {
        return null;
      }
    }
    final file = File(transcriptFileFor(path, agentId) ?? path);
    try {
      final size = await file.length();
      // A wider look only when one long turn hides the last model named.
      for (final bytes in const [262144, 4194304]) {
        final tail = await _tail(file, bytes: bytes);
        final reading = reader.latestIn(const LineSplitter().convert(tail));
        if (reading != null) return reading;
        if (size <= bytes) return null;
      }
    } on FileSystemException {
      return null;
    }
    return null;
  }

  Future<void> close() async {
    final open = _storeServers.values.toList(growable: false);
    _storeServers.clear();
    for (final client in open) {
      await client.close();
    }
  }

  Future<AgentFileChangesReading> _fromStoreServer(
    String sessionId,
    String agentId,
  ) async {
    final row = sessions.getById(sessionId);
    final conversation = row?.externalSessionId ?? '';
    if (row == null || conversation.isEmpty) {
      return const AgentFileChangesReading(
        gap: SessionRecordGap.noConversationYet,
      );
    }
    final executable = rows.installation(row.agentInstallationId)?.executable;
    final environment = executable == null
        ? null
        : rows.environment(executable.environmentId);
    if (executable == null || environment == null) {
      return const AgentFileChangesReading(
        gap: SessionRecordGap.recordUnreadable,
        detail: 'no environment row',
      );
    }
    final key = (environment.id, agentId);
    var client = _storeServers[key];
    if (client == null) {
      final server = registry.adapterFor(agentId)?.storeServer;
      final name =
          registry.adapterFor(agentId)?.presentation.shortName ?? agentId;
      if (server == null) {
        return AgentFileChangesReading(
          gap: SessionRecordGap.recordUnreadable,
          detail: 'no $name to ask on ${environment.name}',
        );
      }
      try {
        final runner = runners.forEnvironment(environment);
        client = server.open(
          connect: () => runner.start(
            CommandRequest(
              executable: executable.path,
              arguments: server.arguments,
            ),
          ),
          clientVersion: kHostVersion,
        );
      } on Object catch (error) {
        return AgentFileChangesReading(
          gap: SessionRecordGap.recordUnreadable,
          detail: 'no $name to ask on ${environment.name}: $error',
        );
      }
      _storeServers[key] = client;
    }
    try {
      final result = await client.listFileChanges(conversation);
      final failure = result.failure;
      if (failure != null) {
        return AgentFileChangesReading(
          gap: SessionRecordGap.recordUnreadable,
          detail: failure,
        );
      }
      return AgentFileChangesReading(changes: result.changes);
    } on Object catch (error) {
      return AgentFileChangesReading(
        gap: SessionRecordGap.recordUnreadable,
        detail: '$error',
      );
    }
  }
}

/// Every edit [path]'s lines record, oldest first, streamed.
Future<List<StoreServerFileChange>> _editsIn(
  String path,
  List<FileEditRecord> Function(Map<String, Object?> json) editsOnLine,
) async {
  final changes = <StoreServerFileChange>[];
  await for (final line in File(
    path,
  ).openRead().transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) continue;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (decoded is! Map<String, Object?>) continue;
    for (final edit in editsOnLine(decoded)) {
      changes.add(StoreServerFileChange(path: edit.path, kind: edit.kind));
    }
  }
  return changes;
}

/// The end of a record: a question is the newest thing in it while open.
Future<String> _tail(File file, {int bytes = 65536}) async {
  final handle = await file.open();
  try {
    final size = await handle.length();
    final start = size > bytes ? size - bytes : 0;
    await handle.setPosition(start);
    return const Utf8Decoder(
      allowMalformed: true,
    ).convert(await handle.read(size - start));
  } finally {
    await handle.close();
  }
}
