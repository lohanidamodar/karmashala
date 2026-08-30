import 'dart:async';

import '../../agents/data/agent_status_service.dart';
import '../../agents/domain/agent_status.dart';
import '../domain/agent_session_key.dart';
import '../domain/agent_status_transition.dart';
import '../domain/inbox_item.dart';
import '../domain/notification_policy.dart';
import '../domain/notification_request.dart';
import '../domain/notification_settings.dart';
import '../domain/session_attention.dart';
import '../domain/watched_session.dart';

/// Polls the agent status pipeline, turns what changed into decisions, and
/// keeps the set of sessions that need the user up to date.
///
/// Two outputs, deliberately different in kind:
///
/// * [onAttention] is **state** — everything currently waiting on the user.
///   It is recomputed every poll and is never gated on focus, because the tray
///   is ambient.
/// * [onNotify] is an **event** — a transition the policy judged worth
///   interrupting for. It goes through the dispatcher, which coalesces.
///
/// Collaborators are passed in as functions rather than read from a container,
/// so the whole loop can be driven in a test with a real [AgentStatusService]
/// and no window, database or agent.
class AgentStatusWatcher {
  AgentStatusWatcher({
    required this.statusService,
    required this.loadSessions,
    required this.readSettings,
    required this.isWindowFocused,
    required this.visibleSessionIds,
    required this.onAttention,
    required this.onNotify,
    this.onInbox,
    this.policy = const AgentNotificationPolicy(),
    this.interval = const Duration(seconds: 5),
  });

  final AgentStatusService statusService;

  /// The sessions worth asking about this tick — bounded by the caller, since
  /// every entry costs a status lookup.
  final List<WatchedSession> Function() loadSessions;

  final NotificationSettings Function() readSettings;
  final bool Function() isWindowFocused;
  final Set<String> Function() visibleSessionIds;
  final void Function(List<SessionAttention> attention) onAttention;
  final void Function(PendingNotification event) onNotify;

  /// Everything one poll saw, for the attention inbox: what is waiting, what
  /// was looked at, and what changed.
  ///
  /// A third output rather than a reshaping of the first two, because the inbox
  /// needs a fact neither of them carries — *which sessions the watcher could
  /// still see*. Without it an inbox cannot tell "the approval was answered"
  /// from "we lost sight of the session", and Loop 42's tray silently dropped
  /// the second case.
  final void Function(InboxUpdate update)? onInbox;

  final AgentNotificationPolicy policy;
  final Duration interval;

  final Map<AgentSessionKey, AgentActivityStatus> _lastStatus = {};
  Timer? _timer;
  bool _polling = false;

  /// The last status observed for [key], for tests and diagnostics.
  AgentActivityStatus? lastStatusOf(AgentSessionKey key) => _lastStatus[key];

  void start() {
    if (_timer != null) return;
    unawaited(poll());
    _timer = Timer.periodic(interval, (_) => unawaited(poll()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    stop();
    _lastStatus.clear();
  }

  /// One pass: read every watched session's status, diff it against the last
  /// pass, and publish the results.
  Future<void> poll() async {
    // A slow filesystem must not let two passes interleave and produce a
    // transition against a half-updated snapshot.
    if (_polling) return;
    _polling = true;
    try {
      final sessions = loadSessions();
      final settings = readSettings();
      final focused = isWindowFocused();
      final visible = visibleSessionIds();

      final attention = <SessionAttention>[];
      final seen = <AgentSessionKey>{};
      final news = <({WatchedSession session, NotificationReason reason})>[];

      for (final session in sessions) {
        seen.add(session.key);
        final report = await statusService.statusFor(
          AgentStatusQuery(
            agentId: session.key.agentId,
            sessionId: session.key.sessionId,
            stateFilePath: session.stateFilePath,
          ),
        );

        final previous = _lastStatus[session.key];
        _lastStatus[session.key] = report.status;

        // What happened, before anything about whether to interrupt. The inbox
        // takes this; the toast takes the gated form below.
        final reason = policy
            .newsIn(
              AgentStatusTransition(
                session: session.key,
                from: previous,
                to: report.status,
                source: report.source,
              ),
            )
            .reason;
        if (reason != null) news.add((session: session, reason: reason));

        final decision = policy.decide(
          NotificationContext(
            transition: AgentStatusTransition(
              session: session.key,
              from: previous,
              to: report.status,
              source: report.source,
            ),
            settings: settings,
            windowFocused: focused,
            visibleSessionIds: visible,
          ),
        );
        if (decision.shouldNotify) {
          onNotify(
            PendingNotification(session: session, reason: decision.reason!),
          );
        }

        final kind = _attentionKind(report.status);
        if (kind != null) {
          attention.add(SessionAttention(session: session, kind: kind));
        }
      }

      // Forget sessions that fell out of the watch set. If one comes back it is
      // a first observation again, which the policy treats as "no evidence
      // anything just changed" — the conservative answer.
      _lastStatus.removeWhere((key, _) => !seen.contains(key));
      onAttention(attention);
      onInbox?.call(InboxUpdate(waiting: attention, watched: seen, news: news));
    } finally {
      _polling = false;
    }
  }

  AttentionKind? _attentionKind(AgentActivityStatus status) => switch (status) {
    AgentActivityStatus.awaitingApproval => AttentionKind.needsInput,
    AgentActivityStatus.failed => AttentionKind.failed,
    _ => null,
  };
}
