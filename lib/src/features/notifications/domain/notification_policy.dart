import '../../agents/domain/agent_status.dart';
import '../../github/domain/pull_request_snapshot.dart';
import '../../sessions/domain/session_delivery.dart';
import 'delivery_transition.dart';
import 'agent_status_transition.dart';
import 'notification_settings.dart';

/// Why a status change is worth interrupting someone for.
enum NotificationReason {
  /// An agent stopped working — its turn is over.
  finished,

  /// An agent is waiting for the user to approve something.
  needsInput,

  /// An agent ended in error.
  failed,

  /// A pull request's checks went red.
  checksFailed,

  /// A reviewer asked for changes.
  changesRequested,

  /// A pull request is green, unblocked and waiting for someone to press
  /// merge.
  readyToMerge;

  /// Whether this is about delivery rather than about the agent's turn.
  bool get isDelivery =>
      this == checksFailed || this == changesRequested || this == readyToMerge;
}

/// Why a status change was *not* delivered. Recorded rather than discarded so
/// the rule is testable and a "why did I not get told?" question has an answer.
enum NotificationSuppression {
  /// The user turned notifications off.
  notificationsDisabled,

  /// The status did not actually change.
  notAChange,

  /// Nothing can tell us what the session is doing any more. Losing track is
  /// not news.
  lostTrack,

  /// A real change, but not one worth an interruption (an agent *starting*
  /// work, most often).
  notWorthInterrupting,

  /// We cannot show that this happened just now: no hook fired, and the
  /// previous status was unknown or never observed.
  noEvidenceOfChange,

  /// The user turned off this class of notification.
  reasonMuted,

  /// This is the session on screen right now.
  sessionOnScreen,

  /// The window has focus and the user asked to only be told when it does not.
  windowFocused,
}

/// The outcome of [AgentNotificationPolicy.decide]: either a reason to notify
/// or the reason it was held back.
class NotificationDecision {
  const NotificationDecision.notify(NotificationReason this.reason)
    : suppression = null;

  const NotificationDecision.suppress(NotificationSuppression this.suppression)
    : reason = null;

  final NotificationReason? reason;
  final NotificationSuppression? suppression;

  bool get shouldNotify => reason != null;

  @override
  String toString() => shouldNotify
      ? 'notify(${reason!.name})'
      : 'suppress(${suppression!.name})';
}

/// Everything the policy is allowed to look at. A plain value object, so the
/// rule can be exercised without a window, a database or an agent.
class NotificationContext {
  const NotificationContext({
    required this.transition,
    required this.settings,
    required this.windowFocused,
    this.visibleSessionIds = const {},
  });

  final AgentStatusTransition transition;
  final NotificationSettings settings;

  /// Whether the app window currently has OS focus.
  final bool windowFocused;

  /// CLI session ids currently rendered in the app (the selected native and
  /// imported sessions). Only counts as "on screen" while [windowFocused].
  final Set<String> visibleSessionIds;
}

/// Decides whether one agent status change deserves to interrupt the user.
///
/// The rule, in one sentence: **notify only when an agent has just finished a
/// turn or just started waiting on you, we can show it happened now, and you
/// are not already looking at it.**
///
/// Everything else — an agent picking work up, a session we have lost track of,
/// the first sighting of a session that was already in that state when the app
/// started — is deliberately silent. Most status transitions are noise, and an
/// app that interrupts on all of them gets its notifications switched off.
class AgentNotificationPolicy {
  const AgentNotificationPolicy();

  /// The news in [transition] — the half of the rule that is about the
  /// **agent**, with nothing in it about the user's attention.
  ///
  /// Split out so the attention inbox and the toast share one classifier. They
  /// must agree about what happened and disagree only about whether it is worth
  /// interrupting for: an inbox that used its own rules would list things no
  /// toast ever mentioned, and the two counts would drift apart within a day.
  ///
  /// Returns `notify(reason)` when there is news, and the suppression that
  /// explains its absence when there is not.
  NotificationDecision newsIn(AgentStatusTransition transition) {
    if (transition.from == transition.to) {
      return const NotificationDecision.suppress(
        NotificationSuppression.notAChange,
      );
    }
    if (transition.to == AgentActivityStatus.unknown) {
      return const NotificationDecision.suppress(
        NotificationSuppression.lostTrack,
      );
    }
    final reason = _classify(transition);
    if (reason == null) {
      return const NotificationDecision.suppress(
        NotificationSuppression.notWorthInterrupting,
      );
    }
    if (!_justHappened(transition)) {
      return const NotificationDecision.suppress(
        NotificationSuppression.noEvidenceOfChange,
      );
    }
    return NotificationDecision.notify(reason);
  }

  /// The news in one session's delivery state — the same classifier, applied to
  /// the other half of what a session can be waiting on.
  ///
  /// It lives here, beside [newsIn], for the reason [newsIn] was split out in
  /// the first place: the inbox and the toast must agree about *what happened*
  /// and disagree only about whether it is worth interrupting for. A second
  /// classifier somewhere else would list things no toast ever mentioned.
  ///
  /// **One item per session at a time.** A pull request can be red, unreviewed
  /// and unmergeable at once; reporting all three would turn a work list into a
  /// log. [deliveryNewsIn] names the most actionable of them, and a change
  /// between two of those is itself news.
  NotificationDecision newsInDelivery(DeliveryTransition transition) {
    final now = deliveryNewsIn(transition.to);
    if (now == null) {
      return const NotificationDecision.suppress(
        NotificationSuppression.notWorthInterrupting,
      );
    }
    // A missing previous snapshot counts as "was not true", so a check that
    // went red while the app was closed is still news the first time it is
    // seen. It cannot repeat: the same state next poll is not a change, and the
    // inbox keys an item by its kind and session anyway.
    if (deliveryNewsIn(transition.from) == now) {
      return const NotificationDecision.suppress(
        NotificationSuppression.notAChange,
      );
    }
    return NotificationDecision.notify(now);
  }

  /// What, if anything, a session's delivery state is asking of the user.
  ///
  /// A failing build first: it is the most concrete and the one the agent can
  /// act on without a human. Readiness comes last because it is good news, and
  /// good news does not outrank a blocker.
  NotificationReason? deliveryNewsIn(SessionDelivery? delivery) {
    final pr = delivery?.pullRequest;
    if (pr == null || !pr.isOpen) return null;
    if (pr.checks.state == ChecksState.failing) {
      return NotificationReason.checksFailed;
    }
    if (pr.reviewDecision == ReviewDecision.changesRequested) {
      return NotificationReason.changesRequested;
    }
    if (pr.isReadyToMerge) return NotificationReason.readyToMerge;
    return null;
  }

  NotificationDecision decide(NotificationContext context) {
    final settings = context.settings;
    if (!settings.enabled) {
      return const NotificationDecision.suppress(
        NotificationSuppression.notificationsDisabled,
      );
    }

    final transition = context.transition;
    final news = newsIn(transition);
    final reason = news.reason;
    if (reason == null) return news;

    if (!_wanted(reason, settings)) {
      return const NotificationDecision.suppress(
        NotificationSuppression.reasonMuted,
      );
    }

    // Being told about the thing already on your screen is the fastest way to
    // make someone turn notifications off. "On screen" means the window has
    // focus too: a selected session behind another app is not being looked at.
    if (context.windowFocused &&
        context.visibleSessionIds.contains(transition.session.sessionId)) {
      return const NotificationDecision.suppress(
        NotificationSuppression.sessionOnScreen,
      );
    }

    if (context.windowFocused && settings.onlyWhenUnfocused) {
      return const NotificationDecision.suppress(
        NotificationSuppression.windowFocused,
      );
    }

    return NotificationDecision.notify(reason);
  }

  /// Maps a transition onto the two things that plausibly matter: an agent
  /// needs you, or an agent is done. `working` is never news — starting is not
  /// an event anyone wants a toast for.
  NotificationReason? _classify(AgentStatusTransition transition) =>
      switch (transition.to) {
        AgentActivityStatus.awaitingApproval => NotificationReason.needsInput,
        AgentActivityStatus.failed => NotificationReason.failed,
        // Any known state settling into idle is a turn ending. `from` can only
        // be idle here when it equals `to`, which was already rejected.
        AgentActivityStatus.idle => NotificationReason.finished,
        AgentActivityStatus.working => null,
        AgentActivityStatus.unknown => null,
      };

  /// Whether we can honestly claim the change happened *now*.
  ///
  /// A hook is the agent telling us as it happens, so it always counts. A state
  /// file only counts when we have a previous known status to have moved away
  /// from; otherwise the file may have looked like this for hours and we are
  /// merely reading it for the first time (app start, or a session that has
  /// just become observable).
  bool _justHappened(AgentStatusTransition transition) =>
      transition.source == AgentStatusSource.hook ||
      (transition.from != null &&
          transition.from != AgentActivityStatus.unknown);

  bool _wanted(NotificationReason reason, NotificationSettings settings) =>
      switch (reason) {
        NotificationReason.finished => settings.notifyWhenFinished,
        // Delivery news is all "something wants you" — the same switch the user
        // already has, rather than a fourth setting nobody would find.
        NotificationReason.needsInput ||
        NotificationReason.failed ||
        NotificationReason.checksFailed ||
        NotificationReason.changesRequested ||
        NotificationReason.readyToMerge => settings.notifyWhenAttentionNeeded,
      };
}
