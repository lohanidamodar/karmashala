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
import '../domain/automation.dart';
import '../domain/cron_schedule.dart';

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
  late final TextEditingController _prompt;
  late bool _recurring;
  DateTime? _once;
  String? _installationId;
  PermissionSelection? _mode;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _name = TextEditingController(text: existing?.name ?? '');
    _recurring = existing?.schedule.isRecurring ?? true;
    _cron = TextEditingController(text: existing?.schedule.cron ?? '0 3 * * *');
    _once = existing?.schedule.firesAt;
    _prompt = TextEditingController(text: existing?.prompt ?? '');
    _installationId = existing?.agentInstallationId;
    _mode = existing?.permissionMode;
  }

  @override
  void dispose() {
    _name.dispose();
    _cron.dispose();
    _prompt.dispose();
    super.dispose();
  }

  List<AgentInstallation> get _installations {
    final repository = widget.repository!;
    return ref
        .read(agentInstallationDaoProvider)
        .getByEnvironment(repository.path.environmentId);
  }

  AutomationSchedule? get _schedule {
    if (_recurring) {
      return cronRefusal(_cron.text) == null
          ? AutomationSchedule.cron(_cron.text.trim())
          : null;
    }
    final at = _once;
    return at == null ? null : AutomationSchedule.once(at.toUtc());
  }

  /// The automation this form would write, or null when a field is not filled
  /// in yet. Built so the gate can be asked about it *before* it exists.
  Automation? get _candidate {
    final schedule = _schedule;
    final installationId = _installationId;
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
      permissionMode: _mode,
      enabled: existing?.enabled ?? true,
      armedAt: existing?.armedAt ?? DateTime.now().toUtc(),
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
    final refusal = candidate == null ? null : preflight.refusalFor(candidate);
    final scheduleRefusal = _recurring
        ? cronRefusal(_cron.text)
        : _once == null
        ? 'A one-shot needs a moment to fire at.'
        : null;
    final selected = installations
        .where((i) => i.id == _installationId)
        .firstOrNull;
    final descriptor = selected == null ? null : registry.byId(selected.agentId);

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
              recurring: _recurring,
              cronController: _cron,
              once: _once,
              refusal: scheduleRefusal,
              onRecurringChanged: (value) =>
                  setState(() => _recurring = value),
              onCronChanged: () => setState(() {}),
              onPickMoment: _pickMoment,
            ),
            const SizedBox(height: Insets.sm),
            _AgentField(
              installations: installations,
              selectedId: _installationId,
              displayNameFor: registry.displayNameFor,
              onChanged: (value) => setState(() {
                _installationId = value;
                _mode = null;
              }),
            ),
            const SizedBox(height: Insets.sm),
            if (selected != null)
              _PermissionModeField(
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
      _once = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
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
            )
          : candidate.copyWith(armedAt: controller.now()),
    );
    Navigator.of(context).pop();
  }
}

/// Repeating or once, and when.
class _ScheduleFields extends StatelessWidget {
  const _ScheduleFields({
    required this.recurring,
    required this.cronController,
    required this.once,
    required this.refusal,
    required this.onRecurringChanged,
    required this.onCronChanged,
    required this.onPickMoment,
  });

  final bool recurring;
  final TextEditingController cronController;
  final DateTime? once;

  /// Why the schedule cannot be armed as written, or null.
  final String? refusal;
  final ValueChanged<bool> onRecurringChanged;
  final VoidCallback onCronChanged;
  final VoidCallback onPickMoment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final at = once;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A segmented control rather than two radios: `RadioListTile`'s
        // `groupValue` is deprecated in this SDK.
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: true, label: Text('Repeating')),
            ButtonSegment(value: false, label: Text('Once')),
          ],
          selected: {recurring},
          onSelectionChanged: (selection) =>
              onRecurringChanged(selection.first),
        ),
        if (recurring)
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
          )
        else
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
class _AgentField extends StatelessWidget {
  const _AgentField({
    required this.installations,
    required this.selectedId,
    required this.displayNameFor,
    required this.onChanged,
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
class _PermissionModeField extends StatelessWidget {
  const _PermissionModeField({
    required this.agentName,
    required this.support,
    required this.value,
    required this.onChanged,
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
