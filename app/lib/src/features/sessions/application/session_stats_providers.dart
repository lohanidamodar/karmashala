import '../../../core/capabilities/capabilities.dart';
import '../../../core/database/sqlite_row_reader.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show
        DataRefusalCode,
        DataRefused,
        SessionStatsGap,
        SessionStatsReading;
import 'package:riverpod/riverpod.dart';

import '../data/server_session_stats.dart';

import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import 'package:agent_cli/usage.dart';
import '../../environments/application/environment_providers.dart';
import 'session_chat_source.dart';
import 'session_providers.dart';
import 'package:karmashala_session/session.dart';
import 'session_signals.dart';

/// Why a session has no stats to show. Named rather than collapsed into an
/// empty result: only one of the three is worth waiting on.
enum SessionStatsUnavailable {
  /// No such session row — it was archived or deleted while the dialog opened.
  unknownSession,

  /// The agent keeps a store, but not one that records any counts —
  /// Antigravity's, whose payloads are protobuf in an unpublished schema.
  agentRecordsNoCounts,

  /// The store is readable but this session has no file in it yet: a CLI
  /// writes its session file when it starts a turn, not when it launches.
  transcriptNotFound,
}

/// Everything the stats dialog renders, as a plain value, so the four outcomes
/// can be asserted without pumping a frame.
class SessionStatsView {
  const SessionStatsView.computed(
    SessionStats this.stats,
    this.agentName, {
    this.lifetime,
    this.lifetimeUnavailable,
    this.sessionTitle,
  }) : unavailable = null;

  const SessionStatsView.unavailable(
    this.unavailable,
    this.agentName, {
    this.lifetime,
    this.lifetimeUnavailable,
    this.sessionTitle,
  }) : stats = null;

  final SessionStats? stats;
  final SessionStatsUnavailable? unavailable;

  /// The agent's own lifetime totals, **independent of [stats]**: one section
  /// going quiet must not take the other with it.
  final LifetimeStats? lifetime;

  /// Why [lifetime] is absent. Null exactly when [lifetime] is present.
  final LifetimeStatsUnavailable? lifetimeUnavailable;

  /// What to call the agent in the dialog. Empty when the session named none.
  final String agentName;

  /// The session's own title, for the header. Null when there is no row.
  final String? sessionTitle;
}

/// Reads a session's own counts out of whichever store its agent keeps — both
/// transcript-writing agents record them, so nothing types into the session.
///
/// A server that offers `sessions.stats` reads them where the record is
/// (Stage 0 step 9); an older one refuses it `invalid` and this disk is read
/// as before.
class SessionStatsService {
  const SessionStatsService(this._ref);

  final Ref _ref;

  ServerSessionStats? get _server =>
      _ref.read(capabilitiesProvider).statsViaServer
      ? _ref.read(serverSessionStatsProvider)
      : null;

  /// One session's counts and its agent's lifetime totals. [current] skips a
  /// reading the client holds from the server.
  Future<SessionStatsView> statsFor(
    String sessionId, {
    bool current = false,
  }) async {
    final session = _ref.read(sessionsDataProvider).getById(sessionId);
    if (session == null) return _unknownSession;
    if (_server case final server?) {
      try {
        final reading = await server.read(
          sessionId,
          lifetime: true,
          current: current,
        );
        return _viewOf(reading, session);
      } on DataRefused catch (refusal) {
        if (refusal.code != DataRefusalCode.invalid) rethrow;
      }
    }
    return _readHere(session);
  }

  /// The counts of each of [sessionIds], without lifetime totals: one
  /// request through the server, or one read per session of this disk.
  Future<Map<String, SessionStatsView>> countsFor(
    Iterable<String> sessionIds,
  ) async {
    final sessions = _ref.read(sessionsDataProvider);
    final ids = sessionIds.toList(growable: false);
    if (_server case final server?) {
      try {
        final readings = await server.readAll([
          for (final id in ids)
            if (sessions.getById(id) != null) id,
        ]);
        return {
          for (final id in ids)
            id: switch ((sessions.getById(id), readings[id])) {
              (final session?, final reading?) => _viewOf(reading, session),
              _ => _unknownSession,
            },
        };
      } on DataRefused catch (refusal) {
        if (refusal.code != DataRefusalCode.invalid) rethrow;
      }
    }
    return {
      for (final id in ids)
        id: switch (sessions.getById(id)) {
          final session? => await _readHere(session),
          null => _unknownSession,
        },
    };
  }

  static const _unknownSession = SessionStatsView.unavailable(
    SessionStatsUnavailable.unknownSession,
    '',
    lifetimeUnavailable: LifetimeStatsUnavailable.agentKeepsNoAggregate,
  );

  (String?, AgentAdapter?, String) _agentOf(Session session) {
    final agentId = _ref
        .read(agentInstallationsDataProvider)
        .getById(session.agentInstallationId)
        ?.agentId;
    final adapter = agentId == null
        ? null
        : _ref.read(agentRegistryProvider).adapterFor(agentId);
    return (agentId, adapter, adapter?.descriptor.displayName ?? agentId ?? '');
  }

  SessionStatsView _viewOf(SessionStatsReading reading, Session session) {
    final name = _agentOf(session).$3;
    final lifetime = reading.lifetime;
    final lifetimeUnavailable = lifetime != null
        ? null
        : reading.lifetimeGap ?? LifetimeStatsUnavailable.sourceNotFound;
    if (reading.stats case final stats?) {
      return SessionStatsView.computed(
        stats,
        name,
        lifetime: lifetime,
        lifetimeUnavailable: lifetimeUnavailable,
        sessionTitle: session.title,
      );
    }
    return SessionStatsView.unavailable(
      switch (reading.gap) {
        SessionStatsGap.unknownSession => SessionStatsUnavailable.unknownSession,
        SessionStatsGap.agentKeepsNoCounts =>
          SessionStatsUnavailable.agentRecordsNoCounts,
        SessionStatsGap.recordNotFound ||
        SessionStatsGap.none => SessionStatsUnavailable.transcriptNotFound,
      },
      name,
      lifetime: lifetime,
      lifetimeUnavailable: lifetimeUnavailable,
      sessionTitle: session.title,
    );
  }

  /// Today's read of this machine's disk, for a server without
  /// `sessions.stats`.
  Future<SessionStatsView> _readHere(Session session) async {
    final (agentId, adapter, name) = _agentOf(session);

    // Read first and independently of everything below: the two sections
    // answer different questions and neither is a precondition of the other.
    final lifetime = await _lifetimeFor(agentId, adapter, session);

    final stats = adapter?.stats;
    if (stats == null) {
      return SessionStatsView.unavailable(
        SessionStatsUnavailable.agentRecordsNoCounts,
        name,
        lifetime: lifetime.$1,
        lifetimeUnavailable: lifetime.$2,
        sessionTitle: session.title,
      );
    }

    final externalId = session.externalSessionId;
    if (agentId == null || externalId == null || externalId.isEmpty) {
      return SessionStatsView.unavailable(
        SessionStatsUnavailable.transcriptNotFound,
        name,
        lifetime: lifetime.$1,
        lifetimeUnavailable: lifetime.$2,
        sessionTitle: session.title,
      );
    }

    // The same locator the chat view uses, so the store scan that already found
    // this session's file answers for the stats too.
    final path = await _ref
        .read(sessionTranscriptLocatorProvider)
        .locate(agentId: agentId, externalSessionId: externalId);
    if (path == null) {
      return SessionStatsView.unavailable(
        SessionStatsUnavailable.transcriptNotFound,
        name,
        lifetime: lifetime.$1,
        lifetimeUnavailable: lifetime.$2,
        sessionTitle: session.title,
      );
    }

    final counted = await _ref
        .read(sessionStatsReadersProvider)
        .sessionReaderFor(agentId, stats)
        .readSessionStats(path);
    if (counted == null) {
      return SessionStatsView.unavailable(
        SessionStatsUnavailable.transcriptNotFound,
        name,
        lifetime: lifetime.$1,
        lifetimeUnavailable: lifetime.$2,
        sessionTitle: session.title,
      );
    }
    return SessionStatsView.computed(
      counted,
      name,
      lifetime: lifetime.$1,
      lifetimeUnavailable: lifetime.$2,
      sessionTitle: session.title,
    );
  }

  /// The agent's own books, or why there are none. Read from the store home
  /// detection already resolved, so WSL and SSH get their own totals.
  Future<(LifetimeStats?, LifetimeStatsUnavailable?)> _lifetimeFor(
    String? agentId,
    AgentAdapter? adapter,
    Session session,
  ) async {
    final stats = adapter?.stats;
    if (agentId == null || stats == null) {
      return (null, LifetimeStatsUnavailable.agentKeepsNoAggregate);
    }

    final home = await _storeHome(agentId, session);
    if (home == null) {
      return (null, LifetimeStatsUnavailable.sourceNotFound);
    }

    final lifetime = await _ref
        .read(sessionStatsReadersProvider)
        .lifetimeReaderFor(agentId, stats)
        .read(home);
    return lifetime == null
        ? (null, LifetimeStatsUnavailable.sourceNotFound)
        : (lifetime, null);
  }

  /// This agent's store home in the session's environment, falling back to any
  /// that has one — a session whose environment row went still has books.
  Future<String?> _storeHome(String agentId, Session session) async {
    try {
      final environments = _ref.read(environmentsDataProvider).getAll();
      final stores = await _ref
          .read(cliStoreLocatorProvider)
          .locate(environments);
      final wanted = session.workingDirectory?.environmentId;
      String? fallback;
      for (final store in stores) {
        final home = store.homesByAgentId[agentId];
        if (home == null) continue;
        if (store.environmentId == wanted) return home;
        fallback ??= home;
      }
      return fallback;
    } catch (_) {
      return null;
    }
  }
}

/// Whether an agent's own records hold anything countable — a question for its
/// adapter, so an agent that declares no stats answers "no", not zeros.
bool agentStoreRecordsStats(AgentAdapter? adapter) => adapter?.stats != null;

/// One stats reader per agent per app, so the incremental caches behind them
/// are shared with the store scan rather than rebuilt per dialog.
class SessionStatsReaders {
  final Map<String, SessionStatsReader> _sessions = {};
  final Map<String, LifetimeStatsReader> _lifetimes = {};

  SessionStatsReader sessionReaderFor(String agentId, AgentStats stats) =>
      _sessions.putIfAbsent(agentId, stats.sessionStatsReader);

  LifetimeStatsReader lifetimeReaderFor(String agentId, AgentStats stats) =>
      _lifetimes.putIfAbsent(
        agentId,
        () => stats.lifetimeReader(readRows: readSqliteRows),
      );
}

final sessionStatsReadersProvider = Provider<SessionStatsReaders>(
  (ref) => SessionStatsReaders(),
);

final sessionStatsServiceProvider = Provider<SessionStatsService>(
  (ref) => SessionStatsService(ref),
);

/// A session's stats: computed when the dialog opens or the status line's
/// context chip appears, and again when that chip sees a turn end — an
/// on-demand question, never a poll, subscribed to **this row only**. Each
/// asks the server afresh: its row moving is the news a held reading lacks.
final sessionStatsProvider = FutureProvider.autoDispose
    .family<SessionStatsView, String>((ref, sessionId) {
      ref.watchSession(sessionId);
      return ref
          .read(sessionStatsServiceProvider)
          .statsFor(sessionId, current: true);
    });
