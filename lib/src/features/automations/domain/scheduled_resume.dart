/// A session a person asked to have resumed at a moment — usually when the
/// usage window that stopped it resets. One live row per session.
library;

/// How long after a window's reset the resume fires: providers publish the
/// reset a little before the quota is really back.
const Duration kResumeResetMargin = Duration(seconds: 75);

/// How many times a fire may find the account still limited before giving up.
const int kResumeMaxAttempts = 5;

/// First wait when the provider says "still limited" and names no new reset.
/// Doubles per attempt, and is already longer than the usage ask floor.
const Duration kResumeRetryBase = Duration(minutes: 5);

/// Two resets closer than this are the same reset: Codex derives its reset
/// from `reset_after_seconds`, which drifts by seconds between readings.
const Duration kResumeSameReset = Duration(minutes: 2);

/// Who armed a resume when it was the limit setting rather than a click.
const String kResumeScheduledBySetting = 'the usage-limit setting';

enum ScheduledResumeState {
  /// Armed and waiting for its moment.
  pending,

  /// Due, and waiting because something else owns the checkout.
  queued,

  /// Being resumed right now. A row found here at boot was interrupted, and is
  /// failed rather than retried: a second try could send the message twice.
  firing,

  done,
  cancelled,

  /// Due while the app was not running, and too late to run unasked.
  missed,
  failed,

  /// A word from a newer schema. Read, never written.
  unrecognised;

  static ScheduledResumeState fromName(String? name) => values.firstWhere(
    (state) => state.name == name,
    orElse: () => ScheduledResumeState.unrecognised,
  );

  /// Whether something is still expected to happen for this row.
  bool get isLive =>
      this == ScheduledResumeState.pending ||
      this == ScheduledResumeState.queued ||
      this == ScheduledResumeState.firing;

  String get label => switch (this) {
    ScheduledResumeState.pending => 'Scheduled',
    ScheduledResumeState.queued => 'Waiting for the checkout',
    ScheduledResumeState.firing => 'Resuming',
    ScheduledResumeState.done => 'Resumed',
    ScheduledResumeState.cancelled => 'Cancelled',
    ScheduledResumeState.missed => 'Missed',
    ScheduledResumeState.failed => 'Failed',
    ScheduledResumeState.unrecognised =>
      'Recorded in a way this build cannot read',
  };
}

/// What to do when the moment passed while the app was down or asleep.
enum ResumeLatePolicy {
  /// Resume anyway, however late.
  resume,

  /// Beyond the catch-up grace, mark it missed and ask.
  ask;

  static ResumeLatePolicy fromName(String? name) => values.firstWhere(
    (policy) => policy.name == name,
    orElse: () => ResumeLatePolicy.ask,
  );

  String get label => switch (this) {
    ResumeLatePolicy.resume => 'Still resume',
    ResumeLatePolicy.ask => 'Ask me',
  };
}

class ScheduledResume {
  const ScheduledResume({
    required this.id,
    required this.sessionId,
    required this.fireAt,
    required this.state,
    required this.scheduledAt,
    this.accountKey = '',
    this.accountEmail,
    this.windowLabel,
    this.resetsAt,
    this.message = '',
    this.permissionMode,
    this.notify = false,
    this.latePolicy = ResumeLatePolicy.ask,
    this.reason = '',
    this.attempts = 0,
    this.liveWhenScheduled = false,
    this.scheduledBy = 'the user',
    this.finishedAt,
  });

  final String id;
  final String sessionId;

  /// `agentId@environmentId` of the session's agent when this was armed.
  final String accountKey;

  /// The signed-in address the reading named then, so a switched account under
  /// the same key is noticed. Null when the reading named none.
  final String? accountEmail;

  /// The usage window this waits on, or null for a time the user chose —
  /// which is never checked against usage.
  final String? windowLabel;

  /// The reset of [windowLabel] this row is waiting for. Null with a null
  /// [windowLabel], and after a backoff that had no reset to aim at.
  final DateTime? resetsAt;

  /// When to act, UTC: [resetsAt] plus [kResumeResetMargin], or the chosen time.
  final DateTime fireAt;

  /// Sent once the agent is ready. Empty means resume and say nothing.
  final String message;

  /// Canonical permission selection to resume under; null follows the session.
  final String? permissionMode;

  /// Whether the outcome is also announced on the desktop and the phone.
  final bool notify;

  final ResumeLatePolicy latePolicy;
  final ScheduledResumeState state;

  /// Why the row reads the way it does. Never empty once it has ended badly.
  final String reason;

  /// Fires that found the account still limited.
  final int attempts;

  /// Whether the session had a live pane when this was armed. A session that
  /// was not live then and is now was resumed by hand.
  final bool liveWhenScheduled;

  /// Who armed it, in words: the user, or the usage-limit setting.
  final String scheduledBy;

  final DateTime scheduledAt;
  final DateTime? finishedAt;

  bool get sendsMessage => message.trim().isNotEmpty;

  ScheduledResume copyWith({
    String? accountKey,
    String? accountEmail,
    DateTime? resetsAt,
    bool clearResetsAt = false,
    DateTime? fireAt,
    ScheduledResumeState? state,
    String? reason,
    int? attempts,
    DateTime? finishedAt,
  }) => ScheduledResume(
    id: id,
    sessionId: sessionId,
    accountKey: accountKey ?? this.accountKey,
    accountEmail: accountEmail ?? this.accountEmail,
    windowLabel: windowLabel,
    resetsAt: clearResetsAt ? null : resetsAt ?? this.resetsAt,
    fireAt: fireAt ?? this.fireAt,
    message: message,
    permissionMode: permissionMode,
    notify: notify,
    latePolicy: latePolicy,
    state: state ?? this.state,
    reason: reason ?? this.reason,
    attempts: attempts ?? this.attempts,
    liveWhenScheduled: liveWhenScheduled,
    scheduledBy: scheduledBy,
    scheduledAt: scheduledAt,
    finishedAt: finishedAt ?? this.finishedAt,
  );

  @override
  String toString() =>
      'ScheduledResume($id, $sessionId, ${state.name}, due $fireAt)';
}
