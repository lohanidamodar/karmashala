import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/schedules.dart';
import 'package:karmashala_automations/webhooks.dart';

/// What starts an automation, as the editor offers it.
enum DraftTrigger {
  schedule('On a schedule', 'Schedule'),
  event('When something happens', 'Event'),
  webhook('On a webhook', 'Webhook'),
  once('Once', 'Once');

  const DraftTrigger(this.label, this.short);

  final String label;

  /// For the segmented control, which a phone has to fit.
  final String short;
}

/// How a schedule is spelled in the editor. Cron is the advanced one.
enum DraftScheduleMode {
  time('At a time'),
  every('Every interval'),
  cron('Cron');

  const DraftScheduleMode(this.label);

  final String label;
}

/// What an event rule does first.
enum EventFirstStep {
  agent('Start an agent', 'Agent'),
  tell('Tell that session', 'Tell it'),
  nothing('Only notify me', 'Only notify');

  const EventFirstStep(this.label, this.short);

  final String label;

  /// For the segmented control, which a phone has to fit.
  final String short;
}

/// One automation being written: every field the editor shows, plain values
/// so a half-filled form is a state it can be in.
class AutomationDraft {
  const AutomationDraft({
    this.original,
    this.name = '',
    this.repositoryId,
    this.enabled = true,
    this.trigger = DraftTrigger.schedule,
    this.mode = DraftScheduleMode.time,
    this.hour = 9,
    this.minute = 0,
    this.days = kWeekdays,
    this.everyMinutes = 60,
    this.cron = '0 9 * * 1-5',
    this.latePolicy = AutomationLatePolicy.ask,
    this.eventKind = AutomationEventKind.turnFinished,
    this.startsAgent = true,
    this.notifyOnly = false,
    this.requireSignature = true,
    this.callsPerHour = kDefaultWebhookCallsPerHour,
    this.once,
    this.installationId,
    this.modelId,
    this.permissionMode,
    this.prefersReadOnly = false,
    this.worktree = false,
    this.prompt = '',
    this.steps = AutomationSteps.standard,
    this.stopAfterFailures = kDefaultStopAfterFailures,
    this.maxRuntimeMinutes,
  });

  /// The automation this edits, or null for a new one.
  final Automation? original;
  final String name;
  final String? repositoryId;
  final bool enabled;
  final DraftTrigger trigger;
  final DraftScheduleMode mode;
  final int hour;
  final int minute;

  /// ISO weekdays, Monday 1 to Sunday 7.
  final Set<int> days;
  final int everyMinutes;
  final String cron;
  final AutomationLatePolicy latePolicy;
  final AutomationEventKind eventKind;

  /// False only for an event rule that tells the session the event came from
  /// or only notifies.
  final bool startsAgent;

  /// An event rule that starts nothing and tells nobody: only its steps run.
  final bool notifyOnly;
  final bool requireSignature;
  final int callsPerHour;

  /// Local time.
  final DateTime? once;
  final String? installationId;
  final String? modelId;
  final PermissionSelection? permissionMode;

  /// A template's wish, applied when an agent is picked: its read-only mode.
  final bool prefersReadOnly;
  final bool worktree;
  final String prompt;
  final AutomationSteps steps;
  final int stopAfterFailures;
  final int? maxRuntimeMinutes;

  bool get isNew => original == null;

  /// Whether the run starts an agent of its own (and so names one).
  bool get namesAgent => trigger != DraftTrigger.event || startsAgent;

  /// The first step of an event rule.
  EventFirstStep get firstStep => startsAgent
      ? EventFirstStep.agent
      : notifyOnly
      ? EventFirstStep.nothing
      : EventFirstStep.tell;

  AutomationDraft withFirstStep(EventFirstStep step) => copyWith(
    startsAgent: step == EventFirstStep.agent,
    notifyOnly: step == EventFirstStep.nothing,
    steps:
        step == EventFirstStep.nothing &&
            steps.of(AutomationStepKind.notify) == null
        ? steps.put(
            const AutomationStep(
              kind: AutomationStepKind.notify,
              when: AutomationStepWhen.always,
            ),
          )
        : null,
  );

  static AutomationDraft from(Automation a) {
    final schedule = a.schedule;
    final week = schedule.cron == null ? null : timeOfWeekCron(schedule.cron!);
    final trigger = a.webhook != null
        ? DraftTrigger.webhook
        : a.trigger != null
        ? DraftTrigger.event
        : schedule.isOnce
        ? DraftTrigger.once
        : DraftTrigger.schedule;
    return AutomationDraft(
      original: a,
      name: a.name,
      repositoryId: a.repositoryId,
      enabled: a.enabled,
      trigger: trigger,
      mode: schedule.isInterval
          ? DraftScheduleMode.every
          : week != null || schedule.cron == null
          ? DraftScheduleMode.time
          : DraftScheduleMode.cron,
      hour: week?.hour ?? 9,
      minute: week?.minute ?? 0,
      days: week?.days ?? kWeekdays,
      everyMinutes: schedule.gap?.inMinutes ?? 60,
      cron: schedule.cron ?? '0 9 * * 1-5',
      latePolicy: a.latePolicy,
      eventKind: a.trigger?.kind ?? AutomationEventKind.turnFinished,
      startsAgent: a.startsAgent,
      notifyOnly: a.trigger?.action == AutomationEventAction.notifyOnly,
      requireSignature: a.webhook?.requireSignature ?? true,
      callsPerHour: a.webhook?.callsPerHour ?? kDefaultWebhookCallsPerHour,
      once: schedule.firesAt?.toLocal(),
      installationId: a.agentInstallationId.isEmpty
          ? null
          : a.agentInstallationId,
      modelId: a.modelId,
      permissionMode: a.permissionMode,
      worktree: a.worktree,
      prompt: a.prompt,
      steps: a.steps,
      stopAfterFailures: a.stopAfterFailures,
      maxRuntimeMinutes: a.maxRuntime?.inMinutes,
    );
  }

  AutomationDraft copyWith({
    String? name,
    String? repositoryId,
    bool? enabled,
    DraftTrigger? trigger,
    DraftScheduleMode? mode,
    int? hour,
    int? minute,
    Set<int>? days,
    int? everyMinutes,
    String? cron,
    AutomationLatePolicy? latePolicy,
    AutomationEventKind? eventKind,
    bool? startsAgent,
    bool? notifyOnly,
    bool? requireSignature,
    int? callsPerHour,
    DateTime? once,
    String? installationId,
    String? modelId,
    bool clearModel = false,
    PermissionSelection? permissionMode,
    bool clearPermission = false,
    bool? prefersReadOnly,
    bool? worktree,
    String? prompt,
    AutomationSteps? steps,
    int? stopAfterFailures,
    int? maxRuntimeMinutes,
    bool clearMaxRuntime = false,
  }) => AutomationDraft(
    original: original,
    name: name ?? this.name,
    repositoryId: repositoryId ?? this.repositoryId,
    enabled: enabled ?? this.enabled,
    trigger: trigger ?? this.trigger,
    mode: mode ?? this.mode,
    hour: hour ?? this.hour,
    minute: minute ?? this.minute,
    days: days ?? this.days,
    everyMinutes: everyMinutes ?? this.everyMinutes,
    cron: cron ?? this.cron,
    latePolicy: latePolicy ?? this.latePolicy,
    eventKind: eventKind ?? this.eventKind,
    startsAgent: startsAgent ?? this.startsAgent,
    notifyOnly: notifyOnly ?? this.notifyOnly,
    requireSignature: requireSignature ?? this.requireSignature,
    callsPerHour: callsPerHour ?? this.callsPerHour,
    once: once ?? this.once,
    installationId: installationId ?? this.installationId,
    modelId: clearModel ? null : modelId ?? this.modelId,
    permissionMode: clearPermission
        ? null
        : permissionMode ?? this.permissionMode,
    prefersReadOnly: prefersReadOnly ?? this.prefersReadOnly,
    worktree: worktree ?? this.worktree,
    prompt: prompt ?? this.prompt,
    steps: steps ?? this.steps,
    stopAfterFailures: stopAfterFailures ?? this.stopAfterFailures,
    maxRuntimeMinutes: clearMaxRuntime
        ? null
        : maxRuntimeMinutes ?? this.maxRuntimeMinutes,
  );

  /// Why the schedule as spelled cannot be used, or null.
  String? get scheduleProblem => switch (trigger) {
    DraftTrigger.schedule => switch (mode) {
      DraftScheduleMode.time => days.isEmpty ? 'Pick at least one day.' : null,
      DraftScheduleMode.every =>
        everyMinutes < kMinimumInterval.inMinutes
            ? 'The shortest gap is ${kMinimumInterval.inMinutes} minute.'
            : null,
      DraftScheduleMode.cron => cronRefusal(cron),
    },
    DraftTrigger.once => once == null ? 'Pick when it runs.' : null,
    DraftTrigger.event || DraftTrigger.webhook => null,
  };

  AutomationSchedule _schedule(DateTime now) => switch (trigger) {
    DraftTrigger.schedule => switch (mode) {
      DraftScheduleMode.time => AutomationSchedule.cron(
        cronForTimeOfWeek(hour, minute, days),
      ),
      DraftScheduleMode.every => AutomationSchedule.every(
        Duration(minutes: everyMinutes),
      ),
      DraftScheduleMode.cron => AutomationSchedule.cron(cron.trim()),
    },
    DraftTrigger.once => AutomationSchedule.once((once ?? now).toUtc()),
    // Inert for both: neither fires on a clock.
    DraftTrigger.event ||
    DraftTrigger.webhook => AutomationSchedule.once(original?.armedAt ?? now),
  };

  /// This draft in [repositoryId]: the agent is that checkout's, so its
  /// agent, model and mode are picked again.
  AutomationDraft withCheckout(String? repositoryId) => AutomationDraft(
    original: original,
    name: name,
    repositoryId: repositoryId,
    enabled: enabled,
    trigger: trigger,
    mode: mode,
    hour: hour,
    minute: minute,
    days: days,
    everyMinutes: everyMinutes,
    cron: cron,
    latePolicy: latePolicy,
    eventKind: eventKind,
    startsAgent: startsAgent,
    notifyOnly: notifyOnly,
    requireSignature: requireSignature,
    callsPerHour: callsPerHour,
    once: once,
    prefersReadOnly: prefersReadOnly,
    worktree: worktree,
    prompt: prompt,
    steps: steps,
    stopAfterFailures: stopAfterFailures,
    maxRuntimeMinutes: maxRuntimeMinutes,
  );

  /// What is still missing before this can be saved, in words, or null.
  String? get missing {
    if (name.trim().isEmpty) return 'Name it first.';
    if (repositoryId == null) return 'Pick where it runs.';
    if (scheduleProblem case final problem?) return problem;
    if (namesAgent && installationId == null) return 'Pick an agent.';
    if (!notifyOnly && prompt.trim().isEmpty) {
      return namesAgent
          ? 'Say what the agent is told.'
          : 'Say what the session is told.';
    }
    if (trigger == DraftTrigger.webhook) {
      return webhookTemplateRefusal(prompt);
    }
    return null;
  }

  /// The automation this draft would save, dated [now], or null while
  /// [missing] says something is.
  Automation? toAutomation({required String id, required DateTime now}) =>
      missing == null ? _build(id: id, now: now) : null;

  /// The automation as far as it is filled in, for the summary and the gate
  /// to read before it is saved; null until it has a checkout and a schedule
  /// it can read.
  Automation? probe({required DateTime now}) {
    if (repositoryId == null || scheduleProblem != null) return null;
    return _build(id: original?.id ?? 'draft', now: now);
  }

  Automation _build({required String id, required DateTime now}) {
    final before = original;
    return Automation(
      id: before?.id ?? id,
      repositoryId: repositoryId!,
      name: name.trim(),
      schedule: _schedule(now),
      agentInstallationId: namesAgent ? installationId ?? '' : '',
      prompt: prompt.trim(),
      permissionMode: namesAgent ? permissionMode : null,
      enabled: enabled,
      // Saving is authorising what it now says, so the moment moves.
      armedAt: now,
      latePolicy: latePolicy,
      stopAfterFailures: stopAfterFailures,
      consecutiveFailures: before?.consecutiveFailures ?? 0,
      disabledReason: enabled ? null : before?.disabledReason,
      maxRuntime: maxRuntimeMinutes == null
          ? null
          : Duration(minutes: maxRuntimeMinutes!),
      trigger: trigger == DraftTrigger.event
          ? AutomationEventTrigger(
              kind: eventKind,
              action: switch (firstStep) {
                EventFirstStep.agent => AutomationEventAction.startSession,
                EventFirstStep.tell => AutomationEventAction.messageSession,
                EventFirstStep.nothing => AutomationEventAction.notifyOnly,
              },
            )
          : null,
      webhook: trigger == DraftTrigger.webhook
          ? AutomationWebhook(
              hookId: before?.webhook?.hookId ?? '',
              requireSignature: requireSignature,
              callsPerHour: callsPerHour,
            )
          : null,
      modelId: namesAgent ? modelId : null,
      worktree: namesAgent && worktree,
      steps: steps,
    );
  }
}
