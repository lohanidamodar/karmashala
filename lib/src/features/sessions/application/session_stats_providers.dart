import '../../../core/database/sqlite_row_reader.dart';
import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import 'package:agent_cli/usage.dart';
import 'package:agent_cli/read.dart';
import '../../environments/application/environment_providers.dart';
import 'session_chat_source.dart';
import 'session_providers.dart';
import '../domain/session.dart';
import 'session_signals.dart';

/// Why a session has no stats to show.
///
/// Named rather than collapsed into an empty result, because the three say very
/// different things to the user and only one of them is worth waiting on.
enum SessionStatsUnavailable {
  /// No such session row — it was archived or deleted while the dialog opened.
  unknownSession,

  /// The agent keeps a store, but not one that records any counts.
  ///
  /// Antigravity's, today: its conversation payloads are protobuf in an
  /// unpublished schema, so the store yields identity and nothing countable.
  agentRecordsNoCounts,

  /// The agent's store is readable, but this session has no file in it yet.
  ///
  /// A CLI writes its session file when it starts a turn, not when it launches,
  /// so a session that has been opened and not yet spoken to is legitimately
  /// here — and so is one whose store lives on a machine this app cannot read.
  transcriptNotFound,
}

/// Everything the stats dialog renders, as a plain value.
///
/// A value rather than widget state so the four outcomes can be asserted
/// without pumping a frame — the same bargain `UsageChipView` makes.
class SessionStatsView {
  const SessionStatsView.computed(
    SessionStats this.stats,
    this.agentName, {
    this.lifetime,
    this.lifetimeUnavailable,
  }) : unavailable = null;

  const SessionStatsView.unavailable(
    this.unavailable,
    this.agentName, {
    this.lifetime,
    this.lifetimeUnavailable,
  }) : stats = null;

  final SessionStats? stats;
  final SessionStatsUnavailable? unavailable;

  /// The agent's own lifetime totals. **Independent of [stats]**: a session
  /// that has not written a transcript yet still runs on an agent with a
  /// history, and one section going quiet must not take the other with it.
  final LifetimeStats? lifetime;

  /// Why [lifetime] is absent. Null exactly when [lifetime] is present.
  final LifetimeStatsUnavailable? lifetimeUnavailable;

  /// What to call the agent in the dialog. Empty when the session named none.
  final String agentName;
}

/// Reads a session's own counts out of whichever store its agent keeps.
///
/// **Route A for every agent that has a parseable store**, which turns out to
/// be both of the ones that write transcripts: Claude Code records `usage` on
/// every assistant record, and Codex records a cumulative `token_count` after
/// every model call. Neither needs to be asked, so nothing here types into the
/// user's live session.
class SessionStatsService {
  const SessionStatsService(this._ref);

  final Ref _ref;

  Future<SessionStatsView> statsFor(String sessionId) async {
    final session = _ref.read(sessionDaoProvider).getById(sessionId);
    if (session == null) {
      return const SessionStatsView.unavailable(
        SessionStatsUnavailable.unknownSession,
        '',
        lifetimeUnavailable: LifetimeStatsUnavailable.agentKeepsNoAggregate,
      );
    }

    final agentId = _ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId)
        ?.agentId;
    final descriptor = agentId == null
        ? null
        : _ref.read(agentRegistryProvider).byId(agentId);
    final name = descriptor?.displayName ?? agentId ?? '';

    // Read first and independently of everything below: the two sections
    // answer different questions and neither is a precondition of the other.
    final lifetime = await _lifetimeFor(agentId, descriptor, session);

    final format = descriptor?.store?.format;
    if (!agentStoreRecordsStats(descriptor)) {
      return SessionStatsView.unavailable(
        SessionStatsUnavailable.agentRecordsNoCounts,
        name,
        lifetime: lifetime.$1,
        lifetimeUnavailable: lifetime.$2,
      );
    }

    final externalId = session.externalSessionId;
    if (agentId == null || externalId == null || externalId.isEmpty) {
      return SessionStatsView.unavailable(
        SessionStatsUnavailable.transcriptNotFound,
        name,
        lifetime: lifetime.$1,
        lifetimeUnavailable: lifetime.$2,
      );
    }

    // The same locator the chat view uses, so the store scan that already found
    // this session's file answers for the stats too — and, for Claude Code, has
    // already counted them on its way past.
    final path = await _ref
        .read(sessionTranscriptLocatorProvider)
        .locate(agentId: agentId, externalSessionId: externalId);
    if (path == null) {
      return SessionStatsView.unavailable(
        SessionStatsUnavailable.transcriptNotFound,
        name,
        lifetime: lifetime.$1,
        lifetimeUnavailable: lifetime.$2,
      );
    }

    final stats = format == AgentStoreFormat.claudeJsonl
        ? await _ref.read(claudeStatsReaderProvider).readSessionStats(path)
        : await _ref.read(codexStatsReaderProvider).readSessionStats(path);
    if (stats == null) {
      return SessionStatsView.unavailable(
        SessionStatsUnavailable.transcriptNotFound,
        name,
        lifetime: lifetime.$1,
        lifetimeUnavailable: lifetime.$2,
      );
    }
    return SessionStatsView.computed(
      stats,
      name,
      lifetime: lifetime.$1,
      lifetimeUnavailable: lifetime.$2,
    );
  }

  /// The agent's own books, or why there are none.
  ///
  /// Read from the store home the rest of detection already resolves, so a WSL
  /// or SSH environment gets its own agent's totals rather than the host's.
  Future<(LifetimeStats?, LifetimeStatsUnavailable?)> _lifetimeFor(
    String? agentId,
    AgentDescriptor? descriptor,
    Session session,
  ) async {
    final format = descriptor?.store?.format;
    if (agentId == null ||
        (format != AgentStoreFormat.claudeJsonl &&
            format != AgentStoreFormat.codexRollout)) {
      return (null, LifetimeStatsUnavailable.agentKeepsNoAggregate);
    }

    final home = await _storeHome(agentId, session);
    if (home == null) {
      return (null, LifetimeStatsUnavailable.sourceNotFound);
    }

    final stats = format == AgentStoreFormat.claudeJsonl
        ? await _ref.read(claudeLifetimeReaderProvider).read(home)
        : await _ref.read(codexLifetimeReaderProvider).read(home);
    return stats == null
        ? (null, LifetimeStatsUnavailable.sourceNotFound)
        : (stats, null);
  }

  /// This agent's store home in the environment the session runs in, falling
  /// back to any environment that has one — a session whose environment row has
  /// gone is still running against some agent's books.
  Future<String?> _storeHome(String agentId, Session session) async {
    try {
      final environments = _ref.read(executionEnvironmentDaoProvider).getAll();
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

/// Whether an agent's own store records anything countable.
///
/// A capability query over what the registry already declares, deliberately not
/// a new flag on [AgentDescriptor] — the same shape as `agentSupportsChatView`,
/// and for the same reason: a store format is the fact, and a second field
/// saying the same thing is a second field to keep in step. An agent whose
/// format is unknown answers "no", so the affordance is simply absent rather
/// than showing zeros.
bool agentStoreRecordsStats(AgentDescriptor? descriptor) {
  final format = descriptor?.store?.format;
  return format == AgentStoreFormat.claudeJsonl ||
      format == AgentStoreFormat.codexRollout;
}

/// One reader per app, so the incremental caches behind them are shared with
/// the store scan rather than rebuilt per dialog.
final claudeStatsReaderProvider = Provider<ClaudeStoreReader>(
  (ref) => ClaudeStoreReader(),
);

final codexStatsReaderProvider = Provider<CodexStatsReader>(
  (ref) => CodexStatsReader(),
);

final claudeLifetimeReaderProvider = Provider<ClaudeLifetimeReader>(
  (ref) => ClaudeLifetimeReader(),
);

final codexLifetimeReaderProvider = Provider<CodexLifetimeReader>(
  (ref) => const CodexLifetimeReader(readRows: readSqliteRows),
);

final sessionStatsServiceProvider = Provider<SessionStatsService>(
  (ref) => SessionStatsService(ref),
);

/// A session's stats, computed once per dialog opening.
///
/// `autoDispose` and watched by nothing else: this is an on-demand question,
/// not a poll. It subscribes to **this row only** — a rename or a launch
/// anywhere else in the app must not re-run a read that walks the store — and
/// to that row it must, because the CLI conversation a session points at is
/// exactly what the answer is about.
final sessionStatsProvider = FutureProvider.autoDispose
    .family<SessionStatsView, String>((ref, sessionId) {
      ref.watchSession(sessionId);
      return ref.read(sessionStatsServiceProvider).statsFor(sessionId);
    });
