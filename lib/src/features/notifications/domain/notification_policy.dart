import '../../agents/domain/agent_status.dart';
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

  NotificationDecision decide(NotificationContext context) {
    final settings = context.settings;
    if (!settings.enabled) {
      return const NotificationDecision.suppress(
        NotificationSuppression.notificationsDisabled,
      );
    }

    final transition = context.transition;
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
        NotificationReason.needsInput ||
        NotificationReason.failed => settings.notifyWhenAttentionNeeded,
      };
}
