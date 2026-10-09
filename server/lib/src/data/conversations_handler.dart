import 'dart:async';
import 'dart:io';

import 'package:agent_cli/descriptors.dart' show AgentRegistry;
import 'package:agent_cli/process.dart'
    show CommandRunnerFactory, ExecutionEnvironment, localHostEnvironment;
import 'package:agent_cli/read.dart' show CliStoreLocator;
import 'package:karmashala_conversations/store.dart';
import 'package:karmashala_core/util.dart' show Clock;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/store.dart'
    show ExecutionEnvironmentDao;
import 'package:karmashala_store/database.dart';

/// The conversation index, kept by the server: it reads the transcripts of
/// the conversations its session rows and imported history name, through the
/// agent adapters, and answers the searches every client asks.
///
/// Nothing is read until [start] gives it the agents' stores ([TranscriptStores]):
/// a service without them still searches what is indexed.
class ConversationsHandler {
  ConversationsHandler(AppDatabase database, Clock clock)
    : dao = ConversationIndexDao(database),
      _clock = clock {
    indexer = ConversationIndexer(dao: dao, clock: clock);
    search = SessionSearchService(dao: dao, clock: clock, indexer: indexer);
  }

  final ConversationIndexDao dao;
  final Clock _clock;
  late final ConversationIndexer indexer;
  late final SessionSearchService search;

  TranscriptStores? _stores;
  Duration _drainAfter = const Duration(seconds: 2);
  Timer? _drainTimer;
  Future<int>? _draining;
  Future<int>? _backfill;
  var _backfilling = false;

  /// Which session rows' conversations are their `session_messages` (an ACP
  /// agent's), read from there: no agent store holds them.
  bool Function(String rowId) _servesFromMessages = _none;
  static bool _none(String _) => false;

  /// Starts keeping the index: every conversation a written row names is
  /// read [drainAfter] later (the writes of one turn come in bursts).
  void start(
    TranscriptStores stores, {
    Duration? drainAfter,
    bool Function(String rowId)? servesFromMessages,
  }) {
    _stores = stores;
    if (drainAfter != null) _drainAfter = drainAfter;
    if (servesFromMessages != null) _servesFromMessages = servesFromMessages;
  }

  /// Session row [rowId]'s `session_messages` changed: its conversation is
  /// read again on the next drain.
  void messagesChanged(String rowId) {
    if (_stores == null || !_servesFromMessages(rowId)) return;
    final conversation = dao.conversationOfRow(rowId);
    if (conversation == null) return;
    indexer.want(
      conversation.conversationId,
      cli: conversation.cli,
      filePath: recordedConversationPath(rowId),
    );
    _schedule();
  }

  /// Queues the conversations [changes] name — a session row that has one, an
  /// imported record with its transcript — and schedules a drain.
  void noticed(List<DataChange> changes) {
    if (_stores == null) return;
    for (final change in changes) {
      switch (change) {
        case SessionRowChanged(:final session):
          final conversation = session.externalSessionId;
          if (conversation != null && conversation.isNotEmpty) {
            indexer.want(
              conversation,
              filePath: _servesFromMessages(session.id)
                  ? recordedConversationPath(session.id)
                  : null,
            );
          }
        case ImportedChanged(:final session):
          indexer.want(
            session.externalId,
            cli: session.cli,
            filePath: session.filePath,
          );
        default:
          break;
      }
    }
    _schedule();
  }

  void _schedule() {
    if (indexer.hasWork) {
      _drainTimer ??= Timer(_drainAfter, () {
        _drainTimer = null;
        unawaited(drain());
      });
    }
  }

  /// Reads everything queued. One at a time: a drain asked for while one runs
  /// waits for it, then reads what arrived since.
  Future<int> drain() async {
    final stores = _stores;
    if (stores == null) return 0;
    while (_draining != null) {
      await _draining;
    }
    if (!indexer.hasWork) return 0;
    final run = indexer.drain(stores.locate);
    _draining = run;
    try {
      return await run;
    } on Object {
      return 0;
    } finally {
      _draining = null;
    }
  }

  /// The one catch-up over the conversations the workspace already had —
  /// once per store, ever (`conversation_index_backfilled_at`).
  Future<int> backfill() {
    final stores = _stores;
    if (stores == null) return Future.value(0);
    return _backfill ??= () async {
      _backfilling = true;
      try {
        final read = await ConversationIndexBackfill(
          dao: dao,
          indexer: indexer,
          clock: _clock,
          locateTranscripts: stores.all,
        ).runOnce();
        return read + await _catchUpRecorded();
      } on Object {
        // A store closed under it (the server stopping) or a transcript that
        // broke a read: search answers from what is indexed, and the next
        // start tries again unless the stamp was written.
        return 0;
      } finally {
        _backfilling = false;
      }
    }();
  }

  /// Every start, unlike the stamped backfill: the ACP conversations whose
  /// messages moved while nothing was indexing them. One query each when not.
  Future<int> _catchUpRecorded() async {
    var read = 0;
    for (final row in dao.recordedRows()) {
      if (!_servesFromMessages(row.rowId)) continue;
      if (await indexer.indexConversation(
        conversationId: row.conversationId,
        cli: row.cli,
        filePath: recordedConversationPath(row.rowId),
      )) {
        read++;
      }
      await Future<void>.delayed(Duration.zero);
    }
    return read;
  }

  /// `conversations.catchUp`: what the running sessions appended since they
  /// were last read.
  Future<int> catchUp() => _stores == null ? Future.value(0) : search.catchUp();

  SessionSearchPage searchFor(ConversationsSearch request) {
    try {
      return search.search(
        request.query,
        filter: request.filter,
        limit: request.limit.clamp(0, kSessionSearchDepth),
        cursor: request.cursor,
      );
    } on StaleSearchCursor catch (stale) {
      throw DataRefused.invalid(stale.toString());
    } on ArgumentError catch (error) {
      throw DataRefused.invalid('${error.message}');
    }
  }

  List<ConversationTurn> turns(ConversationsTurns request) => dao.turnsOf(
    request.conversationId,
    from: request.from,
    limit: request.limit.clamp(0, 1000),
  );

  ConversationIndexStatus status() {
    final counts = dao.counts();
    final coverage = dao.coverage();
    return ConversationIndexStatus(
      named: coverage.named,
      unindexed: coverage.unindexed,
      unreadable: indexer.unreadable.length,
      conversations: counts.conversations,
      turns: counts.turns,
      generation: dao.generation,
      backfilledAt: dao.backfilledAt,
      backfilling: _backfilling,
      queued: indexer.wantedIds.length,
    );
  }

  void close() {
    _drainTimer?.cancel();
    _drainTimer = null;
    _stores = null;
  }
}

/// Where the agents' stores keep each conversation's transcript, on the
/// machines this server reaches — every store home the locator finds, each
/// asked through its agent's adapter (`AgentStore.transcripts`), so no agent
/// is named here. One walk answers every question for [fresh].
class TranscriptStores {
  TranscriptStores({
    required this.locator,
    required this.environments,
    this.registry = AgentRegistry.builtIn,
    this.fresh = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  /// The server's own stores: this machine and the environments recorded in
  /// [database], each reached the way the companion reaches them.
  factory TranscriptStores.over(AppDatabase database) {
    final environments = ExecutionEnvironmentDao(database);
    return TranscriptStores(
      locator: CliStoreLocator(
        runnerFor: (id) => const CommandRunnerFactory().forEnvironment(
          environments.getById(id) ??
              localHostEnvironment(DateTime.now().toUtc()),
        ),
      ),
      environments: environments.getAll,
    );
  }

  final CliStoreLocator locator;
  final List<ExecutionEnvironment> Function() environments;
  final AgentRegistry registry;
  final Duration fresh;
  final DateTime Function() _now;

  Map<String, String>? _last;
  DateTime? _lastAt;
  Future<Map<String, String>>? _walking;

  /// Walks this machine's stores: `'<agentId>/<conversationId>' → path`.
  int walks = 0;

  /// Every transcript the stores hold. Empty for a store that told us
  /// nothing.
  Future<Map<String, String>> all() {
    final last = _last;
    final at = _lastAt;
    if (last != null && at != null && _now().difference(at) < fresh) {
      return Future.value(last);
    }
    return _walking ??= _walk().whenComplete(() => _walking = null);
  }

  /// Agent [agentId]'s store home in environment [environmentId], else in
  /// any environment that has one — a session whose environment row went
  /// still has books. Null when none does.
  Future<String?> storeHome(String agentId, String? environmentId) async {
    try {
      String? fallback;
      for (final store in await locator.locate(environments())) {
        final home = store.homeFor(agentId);
        if (home == null) continue;
        if (store.environmentId == environmentId) return home;
        fallback ??= home;
      }
      return fallback;
    } on Object {
      return null;
    }
  }

  /// [conversationId]'s transcript in agent [cli]'s store, or null.
  Future<String?> locate(String cli, String conversationId) async =>
      (await all())['$cli/$conversationId'];

  /// [locate], but a miss walks again once the last walk is [maxAge] old,
  /// then tries where the adapter says an unplaced record may be — as the
  /// client's locator does, so a first turn is found in seconds, not 30.
  Future<String?> recordFor(
    String cli,
    String conversationId, {
    Duration maxAge = const Duration(seconds: 3),
  }) async {
    final key = '$cli/$conversationId';
    final cached = (await all())[key];
    if (cached != null) return cached;
    final at = _lastAt;
    if (at == null || _now().difference(at) >= maxAge) {
      final walked = await (_walking ??= _walk().whenComplete(
        () => _walking = null,
      ));
      if (walked[key] case final path?) return path;
    }
    final store = registry.adapterFor(cli)?.store;
    if (store == null) return null;
    try {
      for (final located in await locator.locate(environments())) {
        final home = located.homeFor(cli);
        if (home == null) continue;
        for (final record in store.recordCandidates(home, conversationId)) {
          if (await File(record).exists()) return record;
        }
      }
    } on Object {
      // A store we cannot read is the same answer as one with nothing in it.
    }
    return null;
  }

  // The client's `SessionTranscriptLocator` rule: the same homes and files
  // (Claude `projects/*/<id>.jsonl`; Codex `sessions/**/rollout-…-<id>.jsonl`,
  // walked, never its app-server), the id from the name, which Codex writes as
  // the `session_meta` id the client reads. Unlike it, a record with no cwd
  // yet is kept, so a first turn is found sooner.
  Future<Map<String, String>> _walk() async {
    walks++;
    final found = <String, String>{};
    try {
      for (final store in await locator.locate(environments())) {
        for (final adapter in registry.adapters) {
          final layout = adapter.store;
          final home = store.homeFor(adapter.id);
          if (layout == null || home == null) continue;
          try {
            final transcripts = await layout.transcripts(home);
            transcripts?.forEach((id, path) {
              found.putIfAbsent('${adapter.id}/$id', () => path);
            });
          } on Object {
            // One store we cannot read is that store saying nothing.
          }
        }
      }
    } on Object {
      // No store located is the same answer as stores with nothing in them.
    }
    _last = found;
    _lastAt = _now();
    return found;
  }
}
