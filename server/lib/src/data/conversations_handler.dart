import 'dart:async';

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

  /// Starts keeping the index: every conversation a written row names is
  /// read [drainAfter] later (the writes of one turn come in bursts).
  void start(TranscriptStores stores, {Duration? drainAfter}) {
    _stores = stores;
    if (drainAfter != null) _drainAfter = drainAfter;
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
            indexer.want(conversation);
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
        return await ConversationIndexBackfill(
          dao: dao,
          indexer: indexer,
          clock: _clock,
          locateTranscripts: stores.all,
        ).runOnce();
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
    return ConversationIndexStatus(
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

  /// [conversationId]'s transcript in agent [cli]'s store, or null.
  Future<String?> locate(String cli, String conversationId) async =>
      (await all())['$cli/$conversationId'];

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
