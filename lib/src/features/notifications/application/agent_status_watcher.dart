import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import '../domain/agent_session_key.dart';
import '../domain/agent_status_transition.dart';
import '../domain/evidence_line.dart';
import '../domain/inbox_item.dart';
import '../domain/notification_policy.dart';
import '../domain/notification_request.dart';
import '../domain/notification_settings.dart';
import '../domain/session_attention.dart';
import '../domain/watched_session.dart';
import 'session_status_registry.dart';

/// Turns what changed about an agent's status into decisions. Hooks arrive
/// through [applyHookChange] as they land; [poll] is the fallback pass.
class AgentStatusWatcher {
  AgentStatusWatcher({
    required this.registry,
    required this.readSettings,
    required this.isWindowFocused,
    required this.visibleSessionIds,
    required this.onAttention,
    required this.onNotify,
    this.onInbox,
    this.policy = const AgentNotificationPolicy(),
    this.interval = const Duration(seconds: 5),
  }) {
    // Subscribed from construction, not from [start]: a hook is not something
    // this class schedules, and the subscription costs nothing until one lands.
    _hookChanges = registry.hookChanges.listen(applyHookChange);
  }

  /// Where every session's status already lives.
  final SessionStatusRegistry registry;

  final NotificationSettings Function() readSettings;
  final bool Function() isWindowFocused;
  final Set<String> Function() visibleSessionIds;
  final void Function(List<SessionAttention> attention) onAttention;
  final void Function(PendingNotification event) onNotify;

  /// Everything one poll saw, for the attention inbox. It carries which sessions
  /// the watcher could still see — "answered" is not "lost sight of".
  final void Function(InboxUpdate update)? onInbox;

  final AgentNotificationPolicy policy;
  final Duration interval;

  final Map<AgentSessionKey, AgentActivityStatus> _lastStatus = {};

  /// Everything currently holding the user up, kept between passes: a hook pass
  /// knows one session and still has to publish the whole ambient set.
  Map<AgentSessionKey, SessionAttention> _attention = {};

  StreamSubscription<SessionStatusEntry>? _hookChanges;
  Timer? _timer;
  bool _polling = false;
  bool _disposed = false;

  /// The last status observed for [key], for tests and diagnostics.
  AgentActivityStatus? lastStatusOf(AgentSessionKey key) => _lastStatus[key];

  void start() {
    if (_timer != null) return;
    // The registry cycles faster than this: a badge is being looked at, a toast
    // is not. One timer each, for the whole app.
    registry.start();
    unawaited(poll());
    _timer = Timer.periodic(interval, (_) => unawaited(poll()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    registry.stop();
  }

  void dispose() {
    _disposed = true;
    stop();
    unawaited(_hookChanges?.cancel());
    _hookChanges = null;
    _lastStatus.clear();
    _attention = {};
  }

  /// One pass: take the registry's current view of every watched session, diff
  /// it against the last pass, and publish the results.
  Future<void> poll() async {
    // A slow filesystem must not let two passes interleave and produce a
    // transition against a half-updated snapshot.
    if (_polling || _disposed) return;
    _polling = true;
    try {
      // Read the app's state *before* the cycle is awaited: after an async gap
      // the provider container may be gone, and this runs on a background timer.
      final settings = readSettings();
      final focused = isWindowFocused();
      final visible = visibleSessionIds();
      final cycle = await registry.cycle();
      if (_disposed) return;

      final attention = <AgentSessionKey, SessionAttention>{};
      final seen = <AgentSessionKey>{};
      final news = <({WatchedSession session, NotificationReason reason})>[];
      final details = <AgentSessionKey, String>{};

      for (final entry in cycle.entries) {
        seen.add(entry.key);
        final waiting = _judge(
          entry,
          settings: settings,
          focused: focused,
          visible: visible,
          news: news,
          details: details,
        );
        if (waiting != null) attention[entry.key] = waiting;
      }

      // Forget sessions that fell out of the watch set: one that comes back is
      // a first observation again, which the policy treats as no evidence.
      _lastStatus.removeWhere((key, _) => !seen.contains(key));
      _attention = attention;
      onAttention(attention.values.toList(growable: false));
      onInbox?.call(
        InboxUpdate(
          waiting: attention.values.toList(growable: false),
          watched: seen,
          news: news,
          details: details,
        ),
      );
    } finally {
      _polling = false;
    }
  }

  /// One session whose status a hook just changed — the primary path. A partial
  /// pass: only [poll] sees the whole set, so only it may prune `_lastStatus`.
  void applyHookChange(SessionStatusEntry entry) {
    if (_disposed) return;
    final news = <({WatchedSession session, NotificationReason reason})>[];
    final details = <AgentSessionKey, String>{};
    final waiting = _judge(
      entry,
      settings: readSettings(),
      focused: isWindowFocused(),
      visible: visibleSessionIds(),
      news: news,
      details: details,
    );
    if (waiting == null) {
      _attention.remove(entry.key);
    } else {
      _attention[entry.key] = waiting;
    }
    onAttention(_attention.values.toList(growable: false));
    onInbox?.call(
      InboxUpdate(
        waiting: waiting == null ? const [] : [waiting],
        watched: {entry.key},
        news: news,
        details: details,
      ),
    );
  }

  /// The policy over one session, shared by the full pass and the hook pass so
  /// the two cannot disagree. Appends to [news] and fires [onNotify].
  SessionAttention? _judge(
    SessionStatusEntry entry, {
    required NotificationSettings settings,
    required bool focused,
    required Set<String> visible,
    required List<({WatchedSession session, NotificationReason reason})> news,
    required Map<AgentSessionKey, String> details,
  }) {
    final session = entry.session;
    final report = entry.report;
    final previous = _lastStatus[session.key];
    _lastStatus[session.key] = report.status;

    final transition = AgentStatusTransition(
      session: session.key,
      from: previous,
      to: report.status,
      source: report.source,
      waiting: report.waiting,
    );

    // What happened, before anything about whether to interrupt. The inbox
    // takes this; the toast takes the gated form below.
    final reason = policy.newsIn(transition).reason;
    if (reason != null) news.add((session: session, reason: reason));
    // The inbox is the panel you open *because* you missed the toast, so it
    // gets the same words the toast got rather than less.
    if (evidenceLine(report.evidence) case final line?) {
      details[session.key] = line;
    }

    final decision = policy.decide(
      NotificationContext(
        transition: transition,
        settings: settings,
        windowFocused: focused,
        visibleSessionIds: visible,
      ),
    );
    if (decision.shouldNotify) {
      onNotify(
        PendingNotification(
          session: session,
          reason: decision.reason!,
          evidence: report.evidence,
          waiting: report.waiting,
        ),
      );
    }

    final kind = AttentionKind.forStatus(report.status);
    return kind == null ? null : SessionAttention(session: session, kind: kind);
  }
}
