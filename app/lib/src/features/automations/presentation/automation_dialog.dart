import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_git/repositories.dart';
import '../application/automation_providers.dart';
import '../application/unattended_preflight.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/schedules.dart';

/// Arming an automation, which is the whole of the authorisation. The gate's
/// own sentence disables the button, so it cannot drift from the write's.
class AutomationDialog extends ConsumerStatefulWidget {
  const AutomationDialog({required this.repository, this.existing, super.key});

  final Repository? repository;
  final Automation? existing;

  static Future<void> show(
    BuildContext context, {
    required Repository? repository,
    Automation? existing,
  }) {
    if (repository == null) return Future<void>.value();
    return showDialog<void>(
      context: context,
      builder: (_) =>
          AutomationDialog(repository: repository, existing: existing),
    );
  }

  @override
  ConsumerState<AutomationDialog> createState() => _AutomationDialogState();
}

class _AutomationDialogState extends ConsumerState<AutomationDialog> {
  late final TextEditingController _name;
  late final TextEditingController _cron;
  late final TextEditingController _every;
  late final TextEditingController _prompt;
  late AutomationScheduleKind _kind;
  late bool _everyUnitHours;
  DateTime? _once;
  String? _installationId;
  PermissionSelection? _mode;
  late AutomationLatePolicy _latePolicy;
  late AutomationEventKind _eventKind;
  late AutomationEventAction _eventAction;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    final schedule = existing?.schedule;
    final trigger = existing?.trigger;
    _eventKind = trigger?.kind ?? AutomationEventKind.turnFinished;
    _eventAction = trigger?.action ?? AutomationEventAction.messageSession;
    _name = TextEditingController(text: existing?.name ?? '');
    _kind = switch (schedule) {
      _ when trigger != null => AutomationScheduleKind.event,
      null => AutomationScheduleKind.every,
      _ when schedule.isInterval => AutomationScheduleKind.every,
      _ when schedule.isOnce => AutomationScheduleKind.once,
      _ => AutomationScheduleKind.cron,
    };
    _cron = TextEditingController(text: schedule?.cron ?? '0 3 * * *');
    // Hours when the gap divides into whole ones: "every 2 hours" rather than
    // "every 120 minutes", which is the same schedule and a worse sentence.
    final gap = schedule?.gap ?? const Duration(hours: 1);
    _everyUnitHours = gap.inMinutes % 60 == 0 && gap.inHours >= 1;
    _every = TextEditingController(
      text: '${_everyUnitHours ? gap.inHours : gap.inMinutes}',
    );
    _once = schedule?.firesAt;
    _prompt = TextEditingController(text: existing?.prompt ?? '');
    // A message rule stores no agent; '' is not one the picker can show.
    final storedAgent = existing?.agentInstallationId;
    _installationId = storedAgent == null || storedAgent.isEmpty
        ? null
        : storedAgent;
    _mode = existing?.permissionMode;
    _latePolicy = existing?.latePolicy ?? AutomationLatePolicy.ask;
  }

  @override
  void dispose() {
    _name.dispose();
    _cron.dispose();
    _every.dispose();
    _prompt.dispose();
    super.dispose();
  }

  List<AgentInstallation> get _installations {
    final repository = widget.repository!;
    return ref
        .read(agentInstallationsDataProvider)
        .getByEnvironment(repository.path.environmentId);
  }

  /// The gap the "every" fields spell, or null when they do not spell one.
  Duration? get _gap {
    final value = int.tryParse(_every.text.trim());
    if (value == null || value <= 0) return null;
    return _everyUnitHours ? Duration(hours: value) : Duration(minutes: value);
  }

  AutomationSchedule? get _schedule => switch (_kind) {
    AutomationScheduleKind.every =>
      _gap == null ? null : AutomationSchedule.every(_gap!),
    AutomationScheduleKind.cron =>
      cronRefusal(_cron.text) == null
          ? AutomationSchedule.cron(_cron.text.trim())
          : null,
    AutomationScheduleKind.once =>
      _once == null ? null : AutomationSchedule.once(_once!.toUtc()),
    // Inert: an event rule's schedule is never read, and none is stored.
    AutomationScheduleKind.event => AutomationSchedule.once(
      widget.existing?.armedAt ?? DateTime.now().toUtc(),
    ),
  };

  AutomationEventTrigger? get _trigger => _kind == AutomationScheduleKind.event
      ? AutomationEventTrigger(kind: _eventKind, action: _eventAction)
      : null;

  /// Whether the form needs an agent: every rule but one that messages the
  /// session its event came from.
  bool get _needsAgent =>
      _trigger?.action != AutomationEventAction.messageSession;

  /// Why the schedule as spelled cannot be armed, or null.
  String? get _scheduleRefusal => switch (_kind) {
    AutomationScheduleKind.every =>
      _gap == null
          ? 'How often? A whole number of minutes or hours.'
          : _gap! < kMinimumInterval
          ? 'The shortest gap is ${describeGap(kMinimumInterval)} — below that '
                'the next run is due before the last one could have finished.'
          : null,
    AutomationScheduleKind.cron => cronRefusal(_cron.text),
    AutomationScheduleKind.once =>
      _once == null ? 'A one-shot needs a moment to fire at.' : null,
    AutomationScheduleKind.event => null,
  };

  /// The automation this form would write, or null when a field is not filled
  /// in yet. Built so the gate can be asked about it *before* it exists.
  Automation? get _candidate {
    final schedule = _schedule;
    // A message rule borrows the target session's agent, so it names none.
    final installationId = _needsAgent ? _installationId : '';
    if (schedule == null || installationId == null) return null;
    if (_name.text.trim().isEmpty || _prompt.text.trim().isEmpty) return null;
    final existing = widget.existing;
    return Automation(
      id: existing?.id ?? 'candidate',
      repositoryId: widget.repository!.id,
      name: _name.text.trim(),
      schedule: schedule,
      agentInstallationId: installationId,
      prompt: _prompt.text.trim(),
      permissionMode: _needsAgent ? _mode : null,
      enabled: existing?.enabled ?? true,
      armedAt: existing?.armedAt ?? DateTime.now().toUtc(),
      latePolicy: _latePolicy,
      stopAfterFailures:
          existing?.stopAfterFailures ?? kDefaultStopAfterFailures,
      consecutiveFailures: existing?.consecutiveFailures ?? 0,
      maxRuntime: existing?.maxRuntime,
      trigger: _trigger,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final repository = widget.repository!;
    // Resolved once and handed down, so every field below is a pure widget.
    final registry = ref.watch(agentRegistryProvider);
    final preflight = ref.watch(unattendedPreflightProvider);
    final installations = _installations;
    final candidate = _candidate;
    final refusal = candidate == null || !candidate.startsAgent
        ? null
        : preflight.refusalFor(candidate);
    final isEvent = _kind == AutomationScheduleKind.event;
    final scheduleRefusal = _scheduleRefusal;
    final selected = installations
        .where((i) => i.id == _installationId)
        .firstOrNull;
    final descriptor = selected == null
        ? null
        : registry.byId(selected.agentId);

    return AlertDialog(
      title: DesktopDialogTitle(
        icon: AppIcons.robot,
        title: widget.existing == null
            ? 'Arm an automation in ${repository.name}'
            : 'Edit "${widget.existing!.name}"',
      ),
      content: BoundedDialogContent(
        width: DialogWidth.regular,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'Nightly sweep',
              ),
            ),
            const SizedBox(height: Insets.sm),
            _ScheduleFields(
              kind: _kind,
              cronController: _cron,
              everyController: _every,
              everyUnitHours: _everyUnitHours,
              once: _once,
              refusal: scheduleRefusal,
              onKindChanged: (value) => setState(() => _kind = value),
              onCronChanged: () => setState(() {}),
              onEveryChanged: () => setState(() {}),
              onEveryUnitChanged: (hours) =>
                  setState(() => _everyUnitHours = hours),
              onPickMoment: _pickMoment,
            ),
            const SizedBox(height: Insets.sm),
            if (isEvent)
              _EventFields(
                kind: _eventKind,
                action: _eventAction,
                onKindChanged: (value) => setState(() => _eventKind = value),
                onActionChanged: (value) =>
                    setState(() => _eventAction = value),
              )
            else
              _LatePolicyField(
                value: _latePolicy,
                onChanged: (value) => setState(() => _latePolicy = value),
              ),
            const SizedBox(height: Insets.sm),
            if (_needsAgent) ...[
              AutomationAgentField(
                installations: installations,
                selectedId: _installationId,
                displayNameFor: registry.displayNameFor,
                onChanged: (value) => setState(() {
                  _installationId = value;
                  _mode = null;
                }),
              ),
              const SizedBox(height: Insets.sm),
            ],
            if (selected != null && _needsAgent)
              AutomationPermissionModeField(
                agentName: descriptor?.displayName ?? selected.agentId,
                support: descriptor?.launch.permission,
                value: _mode,
                onChanged: (value) => setState(() => _mode = value),
              ),
            const SizedBox(height: Insets.sm),
            TextField(
              controller: _prompt,
              minLines: 3,
              maxLines: 6,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'What the agent is told',
                hintText: 'Run the checks and fix what broke.',
              ),
            ),
            if (_trigger case final trigger?) ...[
              const SizedBox(height: Insets.sm),
              // The whole rule, plainly, before it is armed.
              Text(
                trigger.describe(
                  checkout: repository.name,
                  prompt: _prompt.text.trim().isEmpty
                      ? '…'
                      : _prompt.text.trim(),
                ),
                key: const ValueKey('event-rule-sentence'),
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (refusal != null) ...[
              const SizedBox(height: Insets.sm),
              Text(
                refusal.reason,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: candidate == null || refusal != null ? null : _save,
          child: Text(widget.existing == null ? 'Arm' : 'Save'),
        ),
      ],
    );
  }

  Future<void> _pickMoment() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _once?.toLocal() ?? now,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 366)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_once?.toLocal() ?? now),
    );
    if (time == null || !mounted) return;
    setState(() {
      _once = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
  }

  void _save() {
    final controller = ref.read(automationControllerProvider);
    final candidate = _candidate!;
    final existing = widget.existing;
    controller.save(
      existing == null
          ? Automation(
              id: controller.newId(),
              repositoryId: candidate.repositoryId,
              name: candidate.name,
              schedule: candidate.schedule,
              agentInstallationId: candidate.agentInstallationId,
              prompt: candidate.prompt,
              permissionMode: candidate.permissionMode,
              enabled: true,
              // The authorisation, dated. Editing one re-dates it: changing
              // what an automation does is authorising the new thing.
              armedAt: controller.now(),
              latePolicy: candidate.latePolicy,
              trigger: candidate.trigger,
            )
          : candidate.copyWith(armedAt: controller.now()),
    );
    Navigator.of(context).pop();
  }
}

/// Repeating or once, and when.
class _ScheduleFields extends StatelessWidget {
  const _ScheduleFields({
    required this.kind,
    required this.cronController,
    required this.everyController,
    required this.everyUnitHours,
    required this.once,
    required this.refusal,
    required this.onKindChanged,
    required this.onCronChanged,
    required this.onEveryChanged,
    required this.onEveryUnitChanged,
    required this.onPickMoment,
  });

  final AutomationScheduleKind kind;
  final TextEditingController cronController;

  /// The number in "every N …". A controller, because a half-typed number is
  /// a state the field has to be able to be in.
  final TextEditingController everyController;
  final bool everyUnitHours;
  final DateTime? once;

  /// Why the schedule cannot be armed as written, or null.
  final String? refusal;
  final ValueChanged<AutomationScheduleKind> onKindChanged;
  final VoidCallback onCronChanged;
  final VoidCallback onEveryChanged;
  final ValueChanged<bool> onEveryUnitChanged;
  final VoidCallback onPickMoment;

  /// Writes the cron a preset stands for, once the user has said when.
  Future<void> _preset(
    BuildContext context, {
    required bool weekdaysOnly,
  }) async {
    final at = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 3, minute: 0),
      helpText: weekdaysOnly ? 'Weekdays at' : 'Every day at',
    );
    if (at == null) return;
    cronController.text =
        '${at.minute} ${at.hour} * * ${weekdaysOnly ? '1-5' : '*'}';
    onCronChanged();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final at = once;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A segmented control rather than radios: `RadioListTile`'s
        // `groupValue` is deprecated in this SDK.
        SegmentedButton<AutomationScheduleKind>(
          segments: const [
            ButtonSegment(
              value: AutomationScheduleKind.every,
              label: Text('Every…'),
            ),
            ButtonSegment(
              value: AutomationScheduleKind.cron,
              label: Text('At a time'),
            ),
            ButtonSegment(
              value: AutomationScheduleKind.once,
              label: Text('Once'),
            ),
            ButtonSegment(
              value: AutomationScheduleKind.event,
              label: Text('When…'),
            ),
          ],
          selected: {kind},
          onSelectionChanged: (selection) => onKindChanged(selection.first),
        ),
        if (kind == AutomationScheduleKind.every)
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 96,
                      child: TextField(
                        controller: everyController,
                        keyboardType: TextInputType.number,
                        onChanged: (_) => onEveryChanged(),
                        decoration: const InputDecoration(labelText: 'Every'),
                      ),
                    ),
                    const SizedBox(width: Insets.sm),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('minutes')),
                        ButtonSegment(value: true, label: Text('hours')),
                      ],
                      selected: {everyUnitHours},
                      onSelectionChanged: (s) => onEveryUnitChanged(s.first),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(top: Insets.xs),
                  child: Text(
                    // The distinction that makes this not sugar over cron, said
                    // where the choice is made rather than in a doc comment.
                    'Measured from the end of one run to the start of the '
                    'next, so a run that takes longer than the gap is never '
                    'followed straight away by another.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          )
        else if (kind == AutomationScheduleKind.cron) ...[
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs),
            child: Wrap(
              spacing: Insets.xs,
              children: [
                // The cron these write is left visible and editable: a preset
                // that hid what it meant would be a fourth thing to learn.
                ActionChip(
                  label: const Text('Every day at…'),
                  onPressed: () => _preset(context, weekdaysOnly: false),
                ),
                ActionChip(
                  label: const Text('Weekdays at…'),
                  onPressed: () => _preset(context, weekdaysOnly: true),
                ),
                ActionChip(
                  label: const Text('Every hour'),
                  onPressed: () {
                    cronController.text = '0 * * * *';
                    onCronChanged();
                  },
                ),
              ],
            ),
          ),
          TextField(
            controller: cronController,
            onChanged: (_) => onCronChanged(),
            decoration: const InputDecoration(
              labelText: 'Schedule',
              hintText: '0 3 * * *',
              helperText:
                  'minute hour day-of-month month day-of-week, '
                  'in this machine\'s own time',
            ),
          ),
        ] else if (kind == AutomationScheduleKind.once)
          Row(
            children: [
              Expanded(
                child: Text(
                  at == null ? 'No moment picked yet.' : 'At ${at.toLocal()}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              TextButton(
                onPressed: onPickMoment,
                child: const Text('Pick a moment'),
              ),
            ],
          ),
        if (refusal case final refusal?)
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs),
            child: Text(
              refusal,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }
}

/// Which installed agent runs it — or why there is none to pick.
class AutomationAgentField extends StatelessWidget {
  const AutomationAgentField({
    required this.installations,
    required this.selectedId,
    required this.displayNameFor,
    required this.onChanged,
    super.key,
  });

  final List<AgentInstallation> installations;
  final String? selectedId;
  final String Function(String agentId) displayNameFor;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (installations.isEmpty) {
      return Text(
        'No agent is installed in this checkout\'s environment, so '
        'there is nothing here to start.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      );
    }
    return DropdownButtonFormField<String>(
      initialValue: selectedId,
      decoration: const InputDecoration(labelText: 'Agent'),
      items: [
        for (final installation in installations)
          DropdownMenuItem(
            value: installation.id,
            child: Text(displayNameFor(installation.agentId)),
          ),
      ],
      onChanged: onChanged,
    );
  }
}

/// The agent's own modes, flat and safest first. Whole selections rather than
/// a picker per axis, because the gate reads the whole selection's rung.
class AutomationPermissionModeField extends StatelessWidget {
  const AutomationPermissionModeField({
    required this.agentName,
    required this.support,
    required this.value,
    required this.onChanged,
    super.key,
  });

  final String agentName;

  /// Null, or not known, when the modes of this agent were never established.
  final AgentPermissionSupport? support;
  final PermissionSelection? value;
  final ValueChanged<PermissionSelection?> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final support = this.support;
    if (support == null || !support.isKnown) {
      return Text(
        unknownAgentReason(agentName),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      );
    }
    final selections = support.selections();
    final resolved = support.normalise(value).canonical;
    return DropdownButtonFormField<String>(
      initialValue: selections.any((s) => s.canonical == resolved)
          ? resolved
          : null,
      decoration: const InputDecoration(
        labelText: 'Permission mode',
        helperText:
            'A mode that stops to ask is refused: nobody would be '
            'there to answer.',
      ),
      items: [
        for (final selection in selections)
          DropdownMenuItem(
            value: selection.canonical,
            // Whole selections rather than axes, so the familiar name is the
            // composed rung's — the one the unattended gate reads.
            child: Text(describeSelectionFamiliar(support, selection)),
          ),
      ],
      onChanged: (value) =>
          onChanged(value == null ? null : PermissionSelection.parse(value)),
    );
  }
}

/// Which shape a trigger is. The dialog's own axis, not the domain's: the
/// domain has three schedule constructors and a trigger beside them, and a
/// segmented control needs one value to be selected.
enum AutomationScheduleKind { every, cron, once, event }

/// Which event, and what to do about it — with the two limits that make an
/// event rule safe to leave armed said where it is armed.
class _EventFields extends StatelessWidget {
  const _EventFields({
    required this.kind,
    required this.action,
    required this.onKindChanged,
    required this.onActionChanged,
  });

  final AutomationEventKind kind;
  final AutomationEventAction action;
  final ValueChanged<AutomationEventKind> onKindChanged;
  final ValueChanged<AutomationEventAction> onActionChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<AutomationEventKind>(
          key: const ValueKey('event-kind'),
          isExpanded: true,
          initialValue: kind,
          decoration: const InputDecoration(labelText: 'When'),
          items: [
            for (final value in AutomationEventKind.values)
              DropdownMenuItem(value: value, child: Text(value.label)),
          ],
          onChanged: (value) => value == null ? null : onKindChanged(value),
        ),
        const SizedBox(height: Insets.sm),
        DropdownButtonFormField<AutomationEventAction>(
          key: const ValueKey('event-action'),
          isExpanded: true,
          initialValue: action,
          decoration: const InputDecoration(labelText: 'Then'),
          items: [
            for (final value in AutomationEventAction.values)
              DropdownMenuItem(value: value, child: Text(value.label)),
          ],
          onChanged: (value) => value == null ? null : onActionChanged(value),
        ),
        Padding(
          padding: const EdgeInsets.only(top: Insets.xs),
          child: Text(
            'Only sessions in this checkout. It never answers an event its '
            'own action caused, fires at most once a second, and never moves '
            'your focus.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// What this automation does about an occurrence the app slept through.
///
/// Per automation, because the right answer is about the work: a nightly
/// dependency sweep is worth running at noon, and a "post the standup summary"
/// is not worth running at all once the standup is over.
class _LatePolicyField extends StatelessWidget {
  const _LatePolicyField({required this.value, required this.onChanged});

  final AutomationLatePolicy value;
  final ValueChanged<AutomationLatePolicy> onChanged;

  @override
  Widget build(BuildContext context) => InputDecorator(
    decoration: const InputDecoration(
      labelText: 'If Karmashala was not running at the time',
      border: InputBorder.none,
      isDense: true,
    ),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<AutomationLatePolicy>(
        value: value,
        isExpanded: true,
        items: [
          for (final policy in AutomationLatePolicy.values)
            DropdownMenuItem(value: policy, child: Text(policy.label)),
        ],
        onChanged: (chosen) => chosen == null ? null : onChanged(chosen),
      ),
    ),
  );
}
