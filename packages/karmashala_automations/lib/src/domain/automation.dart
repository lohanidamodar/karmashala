import 'package:agent_cli/descriptors.dart';

import 'automation_steps.dart';
import 'automation_trigger.dart';
import 'automation_webhook.dart';
import 'github_trigger.dart';

/// The shortest interval an automation may repeat at.
///
/// A run takes a checkout and an agent process; below this the next occurrence
/// is due before the last one could plausibly have finished, and the queue
/// becomes the schedule. Measured from the *finish* rather than the occurrence
/// (see [AutomationSchedule.every]), so this is a floor on the gap, not on the
/// total time a run may take.
const Duration kMinimumInterval = Duration(minutes: 1);

/// When an automation fires: a cron expression, a fixed gap, or one absolute
/// instant. Three kinds, because each loses something as another — a one-shot
/// stored as a cron loses that it is *over*, and a gap stored as a cron loses
/// that it is measured from the last run rather than from the clock.
class AutomationSchedule {
  const AutomationSchedule.cron(String this.cron)
    : firesAt = null,
      everySeconds = null;

  const AutomationSchedule.once(DateTime this.firesAt)
    : cron = null,
      everySeconds = null;

  /// Repeats with [gap] between the **end of one run and the start of the
  /// next**, not between occurrences.
  ///
  /// This is the whole reason interval is not sugar over cron. `*/30 * * * *`
  /// fires on the half hour whether or not the last run finished, so a run
  /// that overruns is immediately followed by another; a gap measured from the
  /// finish cannot overlap itself, which is what makes an unattended recurring
  /// run safe to leave alone.
  AutomationSchedule.every(Duration gap)
    : cron = null,
      firesAt = null,
      everySeconds =
          (gap < kMinimumInterval ? kMinimumInterval : gap).inSeconds;

  const AutomationSchedule._seconds(int this.everySeconds)
    : cron = null,
      firesAt = null;

  /// Reads back what a row stored. Null when the row names no schedule at all.
  static AutomationSchedule? fromRow({
    String? cron,
    DateTime? firesAt,
    int? everySeconds,
  }) {
    if (everySeconds != null && everySeconds > 0) {
      return AutomationSchedule._seconds(everySeconds);
    }
    if (cron != null && cron.isNotEmpty) return AutomationSchedule.cron(cron);
    if (firesAt != null) return AutomationSchedule.once(firesAt);
    return null;
  }

  /// A five-field cron expression, in the machine's own timezone. Null for
  /// every other kind.
  final String? cron;

  /// The absolute instant a one-shot is due, UTC. Null for every other kind.
  final DateTime? firesAt;

  /// The gap after a run finishes, in seconds. Null for every other kind.
  final int? everySeconds;

  bool get isOnce => firesAt != null;
  bool get isInterval => everySeconds != null;
  bool get isRecurring => cron != null || isInterval;

  /// The gap, for an interval schedule.
  Duration? get gap =>
      everySeconds == null ? null : Duration(seconds: everySeconds!);

  /// What a row stores. Exactly one of the three columns is ever set.
  String? get cronText => cron;

  /// `every 90m`, `cron "0 3 * * *"`, `once at …` — for a log line.
  String get describe => switch (this) {
    _ when isOnce => 'once at ${firesAt!.toIso8601String()}',
    _ when isInterval => 'every ${describeGap(gap!)} after each run',
    _ => 'cron "$cron"',
  };

  @override
  bool operator ==(Object other) =>
      other is AutomationSchedule &&
      other.cron == cron &&
      other.firesAt == firesAt &&
      other.everySeconds == everySeconds;

  @override
  int get hashCode => Object.hash(cron, firesAt, everySeconds);

  @override
  String toString() => describe;
}

/// `90m`, `2h`, `1h30m` — the shortest true spelling of [gap].
String describeGap(Duration gap) {
  final hours = gap.inHours;
  final minutes = gap.inMinutes % 60;
  if (hours == 0) return '${gap.inMinutes}m';
  return minutes == 0 ? '${hours}h' : '${hours}h${minutes}m';
}

/// What an automation does about an occurrence it slept through.
enum AutomationLatePolicy {
  /// Run it, however late. For work whose value does not decay.
  run,

  /// Inside the catch-up grace run it; beyond that record a miss and leave it.
  /// The default, and what every automation did before this existed.
  ask,

  /// Record the miss and run nothing. For work that is only useful on time.
  skip;

  static AutomationLatePolicy fromName(String? name) => values.firstWhere(
    (policy) => policy.name == name,
    orElse: () => AutomationLatePolicy.ask,
  );

  String get label => switch (this) {
    AutomationLatePolicy.run => 'Run it, however late',
    AutomationLatePolicy.ask => 'Run it if it is only just late',
    AutomationLatePolicy.skip => 'Skip it and record the miss',
  };
}

/// How many consecutive failures disable an automation by default.
///
/// Without this a broken automation fails every night forever and the only
/// signal is a list of red rows nobody is reading.
const int kDefaultStopAfterFailures = 3;

/// An agent run a person authorised in advance. [armedAt] is the authorisation;
/// there is no `armed_by`, because an agent could write it and make it lie.
class Automation {
  const Automation({
    required this.id,
    required this.repositoryId,
    required this.name,
    required this.schedule,
    required this.agentInstallationId,
    required this.prompt,
    required this.permissionMode,
    required this.enabled,
    required this.armedAt,
    this.latePolicy = AutomationLatePolicy.ask,
    this.stopAfterFailures = kDefaultStopAfterFailures,
    this.consecutiveFailures = 0,
    this.disabledReason,
    this.maxRuntime,
    this.trigger,
    this.webhook,
    this.github,
    this.modelId,
    this.worktree = false,
    this.steps = AutomationSteps.standard,
  });

  final String id;

  /// The checkout it runs in. Its environment is where the gate preflights.
  final String repositoryId;

  /// What the user calls it, so a run row and a refusal name the same thing.
  final String name;

  final AutomationSchedule schedule;

  /// The installation to start — an agent *and* the environment it lives in.
  /// Never resolved to another one; see `UnattendedGateInput.agentInstalled`.
  final String agentInstallationId;

  final String prompt;

  /// The mode it runs under, canonical (`mode=auto`). Null means nobody chose,
  /// which resolves to the agent's declared default.
  final PermissionSelection? permissionMode;

  /// Paused automations keep their row, their runs and their arming.
  final bool enabled;

  /// When a person armed it — the floor a missed-fire sweep counts from.
  final DateTime armedAt;

  /// What it does about an occurrence the app slept through.
  final AutomationLatePolicy latePolicy;

  /// How many failures in a row disable it. Zero means never — a deliberate
  /// choice for an automation whose job is to fail until somebody fixes
  /// something, and the only way to opt out.
  final int stopAfterFailures;

  /// Failures since the last run that did not fail. Reset by any success.
  final int consecutiveFailures;

  /// Why this automation was disabled, when it was not a person who did it.
  /// Null for one a person paused, which needs no explanation.
  final String? disabledReason;

  /// How long a run may hold its checkout before it is failed and the queue
  /// drained. Null is no ceiling, which is what every automation had.
  final Duration? maxRuntime;

  /// The event this fires on, or null for a time-based automation. When set,
  /// [schedule] is inert: the scheduler never fires an event rule on a clock.
  final AutomationEventTrigger? trigger;

  /// What makes this a webhook, or null. A webhook fires on a call to its URL,
  /// never on a clock or an event.
  final AutomationWebhook? webhook;

  /// What makes this answer GitHub, or null. Polled at its own interval,
  /// never on a clock or a session event.
  final AutomationGithubTrigger? github;

  /// The model its agent starts with; null is the agent's default.
  final String? modelId;

  /// Whether each run's session gets a worktree of its own.
  final bool worktree;

  /// What follows the agent: its checks, a message to it, a notification.
  final AutomationSteps steps;

  bool get isEventDriven => trigger != null;

  bool get isWebhook => webhook != null;

  bool get isGithub => github != null;

  /// Whether the scheduler fires this on its [schedule].
  bool get isScheduled => trigger == null && webhook == null && github == null;

  /// Whether a run needs an agent of its own. A message goes into a session
  /// that already has one, so that rule names none; a GitHub rule that tells
  /// a branch's session starts one when no session owns the branch.
  bool get startsAgent => switch (github?.action ?? trigger?.action) {
    null || AutomationEventAction.startSession => true,
    AutomationEventAction.messageSession => github != null,
    AutomationEventAction.notifyOnly => false,
  };

  /// Whether [consecutiveFailures] has reached the limit this was armed with.
  bool get hasFailedOut =>
      stopAfterFailures > 0 && consecutiveFailures >= stopAfterFailures;

  Automation copyWith({
    String? name,
    AutomationSchedule? schedule,
    String? agentInstallationId,
    String? prompt,
    PermissionSelection? permissionMode,
    bool? enabled,
    DateTime? armedAt,
    AutomationLatePolicy? latePolicy,
    int? stopAfterFailures,
    int? consecutiveFailures,
    String? disabledReason,
    bool clearDisabledReason = false,
    Duration? maxRuntime,
    bool clearMaxRuntime = false,
    AutomationEventTrigger? trigger,
    AutomationWebhook? webhook,
    bool clearWebhook = false,
    AutomationGithubTrigger? github,
    String? modelId,
    bool clearModel = false,
    bool? worktree,
    AutomationSteps? steps,
  }) => Automation(
    id: id,
    repositoryId: repositoryId,
    name: name ?? this.name,
    schedule: schedule ?? this.schedule,
    agentInstallationId: agentInstallationId ?? this.agentInstallationId,
    prompt: prompt ?? this.prompt,
    permissionMode: permissionMode ?? this.permissionMode,
    enabled: enabled ?? this.enabled,
    armedAt: armedAt ?? this.armedAt,
    latePolicy: latePolicy ?? this.latePolicy,
    stopAfterFailures: stopAfterFailures ?? this.stopAfterFailures,
    consecutiveFailures: consecutiveFailures ?? this.consecutiveFailures,
    disabledReason: clearDisabledReason
        ? null
        : disabledReason ?? this.disabledReason,
    maxRuntime: clearMaxRuntime ? null : maxRuntime ?? this.maxRuntime,
    trigger: trigger ?? this.trigger,
    webhook: clearWebhook ? null : webhook ?? this.webhook,
    github: github ?? this.github,
    modelId: clearModel ? null : modelId ?? this.modelId,
    worktree: worktree ?? this.worktree,
    steps: steps ?? this.steps,
  );

  @override
  String toString() =>
      'Automation($id, $name, ${webhook ?? github ?? trigger ?? schedule}, '
      'enabled: $enabled)';
}
