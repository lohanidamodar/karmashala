import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_git/github.dart';
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

  /// Whether something is *stopped* until the user acts, rather than merely
  /// having happened. The one table for that question — three callers share it.
  bool get needsUser => this != finished;
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

/// Notify only when an agent has just finished a turn or just started waiting
/// on you, we can show it happened now, and you are not already looking at it.
class AgentNotificationPolicy {
  const AgentNotificationPolicy();

  /// The news in [transition], with nothing in it about the user's attention —
  /// one classifier, so the inbox and the toast cannot describe it differently.
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
    final reason = reasonForStatus(transition.to);
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

  /// The news in one session's delivery state. One item per session at a time:
  /// a PR can be red, unreviewed and unmergeable at once, and this is no log.
  NotificationDecision newsInDelivery(DeliveryTransition transition) {
    final now = deliveryNewsIn(transition.to);
    if (now == null) {
      return const NotificationDecision.suppress(
        NotificationSuppression.notWorthInterrupting,
      );
    }
    // A missing previous snapshot counts as "was not true", so a check that
    // went red while the app was closed is still news the first time it is seen.
    if (deliveryNewsIn(transition.from) == now) {
      return const NotificationDecision.suppress(
        NotificationSuppression.notAChange,
      );
    }
    return NotificationDecision.notify(now);
  }

  /// What, if anything, a session's delivery state is asking of the user. A
  /// failing build first; readiness last, because good news is not a blocker.
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

    // Being told about what is already on your screen is the fastest way to
    // make someone turn notifications off — and behind another app is not on it.
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

  /// What an agent being in [status] means; `working` is never news. The one
  /// table for agent status, shared with [AttentionKind.forStatus].
  static NotificationReason? reasonForStatus(AgentActivityStatus status) =>
      switch (status) {
        AgentActivityStatus.awaitingApproval => NotificationReason.needsInput,
        AgentActivityStatus.failed => NotificationReason.failed,
        // Any known state settling into idle is a turn ending; `from` can only
        // be idle here when it equals `to`, which [newsIn] already rejected.
        AgentActivityStatus.idle => NotificationReason.finished,
        AgentActivityStatus.working => null,
        AgentActivityStatus.unknown => null,
      };

  /// Whether we can honestly claim the change happened *now*. A hook always
  /// counts; a state file may have looked like this for hours.
  bool _justHappened(AgentStatusTransition transition) =>
      transition.source == AgentStatusSource.hook ||
      (transition.from != null &&
          transition.from != AgentActivityStatus.unknown);

  /// Delivery news is all "something wants you" — the same switch the user
  /// already has, rather than a fourth setting nobody would find.
  bool _wanted(NotificationReason reason, NotificationSettings settings) =>
      reason.needsUser
      ? settings.notifyWhenAttentionNeeded
      : settings.notifyWhenFinished;
}
