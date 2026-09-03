import 'dart:async';

import '../../agents/domain/agent_status.dart';
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

/// Turns what changed about an agent's status into decisions, and keeps the set
/// of sessions that need the user up to date.
///
/// **Two inputs, and hooks are the first of them.** A hook report arrives
/// through [applyHookChange] as the callback lands — authoritative, already in
/// memory, and applied to exactly the session it names. [poll] is the fallback:
/// a full pass every [interval] over the registry's latest cycle, for the
/// sessions no hook speaks for and for the membership questions a single hook
/// cannot answer. Before this, a hook waited up to five seconds to be
/// *discovered* by a poll that had to look at everything.
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
    // Subscribed from construction rather than from [start], because a hook is
    // not something this class schedules — it is something that happens to it,
    // and the subscription costs nothing until one does. [dispose] ends it.
    _hookChanges = registry.hookChanges.listen(applyHookChange);
  }

  /// Where every session's status already lives.
  ///
  /// This used to gather them itself — a `for` loop awaiting one transcript
  /// after another over a list somebody else had truncated at 60. It now reads
  /// a cycle the registry produced for the whole app, so the policy runs over
  /// *every* watched session and costs no I/O of its own.
  final SessionStatusRegistry registry;

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

  /// Everything currently holding the user up, in the order the last full pass
  /// found it.
  ///
  /// Kept between passes rather than rebuilt from scratch each time, because a
  /// hook pass knows about exactly one session and still has to publish the
  /// whole ambient set — the tray lists all of it.
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
      // Read the app's state *before* the cycle is awaited. These are cheap
      // synchronous reads of a provider container, and after an async gap the
      // container may be gone — a shutdown that lands mid-poll must not throw
      // out of a background timer.
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

      // Forget sessions that fell out of the watch set. If one comes back it is
      // a first observation again, which the policy treats as "no evidence
      // anything just changed" — the conservative answer.
      //
      // `seen` is now every watched session rather than the first sixty of
      // them, which is what makes that conservatism honest: before Loop 87 a
      // session could be dropped here purely for sorting late, and its next
      // real transition was then swallowed as a first observation.
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

  /// One session, whose status a hook just changed between passes.
  ///
  /// **The primary path.** A hook is authoritative and already in memory, so it
  /// reaches the tray, the inbox and the toast pipeline as it lands rather than
  /// up to [interval] later; [poll] is the fallback for the sessions no hook
  /// speaks for.
  ///
  /// A *partial* pass, and the `watched` set it hands the inbox says so: this
  /// looked at exactly one session, so the inbox retires that session's cleared
  /// condition and nobody else's. `_lastStatus` is not pruned here for the same
  /// reason — "not looked at this pass" is not "no longer watched", and only
  /// [poll], which sees the whole watch set, is entitled to decide the second.
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

  /// The policy over one session: what happened, whether to interrupt for it,
  /// and whether it is still holding the user up.
  ///
  /// Shared by the full pass and the hook pass so the two cannot come to
  /// disagree about what a status means — appending to [news] and firing
  /// [onNotify] as a side effect, and returning the attention it leaves behind.
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
