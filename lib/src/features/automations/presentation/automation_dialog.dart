import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/design_tokens.dart';
import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/descriptors.dart';
import '../../repositories/domain/repository.dart';
import '../application/automation_providers.dart';
import '../application/unattended_preflight.dart';
import '../domain/automation.dart';
import '../domain/cron_schedule.dart';

/// Arming an automation, which is the whole of the authorisation.
///
/// **The gate is shown live, in its own words, and the button is disabled by
/// it.** The sentence under Arm is the same sentence the fire path would throw
/// — one function produces both, so the reason on screen cannot drift from the
/// reason the write refuses with.
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
    final installations = _installations;
    final candidate = _candidate;
    final refusal = candidate == null
        ? null
        : ref.read(unattendedPreflightProvider).refusalFor(candidate);
    final scheduleRefusal = _recurring
        ? cronRefusal(_cron.text)
        : _once == null
        ? 'A one-shot needs a moment to fire at.'
        : null;

    return AlertDialog(
      title: Text(
        widget.existing == null
            ? 'Arm an automation in ${repository.name}'
            : 'Edit "${widget.existing!.name}"',
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
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
              // A segmented control rather than two radios: `RadioListTile`'s
              // `groupValue` is deprecated in this SDK, and the choice is
              // binary anyway.
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Repeating')),
                  ButtonSegment(value: false, label: Text('Once')),
                ],
                selected: {_recurring},
                onSelectionChanged: (selection) =>
                    setState(() => _recurring = selection.first),
              ),
              if (_recurring)
                TextField(
                  controller: _cron,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Schedule',
                    hintText: '0 3 * * *',
                    helperText: 'minute hour day-of-month month day-of-week, '
                        'in this machine\'s own time',
                  ),
                )
              else
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _once == null
                            ? 'No moment picked yet.'
                            : 'At ${_once!.toLocal()}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    TextButton(
                      onPressed: _pickMoment,
                      child: const Text('Pick a moment'),
                    ),
                  ],
                ),
              if (scheduleRefusal != null)
                Padding(
                  padding: const EdgeInsets.only(top: Insets.xs),
                  child: Text(
                    scheduleRefusal,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: Insets.sm),
              if (installations.isEmpty)
                Text(
                  'No agent is installed in this checkout\'s environment, so '
                  'there is nothing here to start.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                )
              else
                DropdownButtonFormField<String>(
                  initialValue: _installationId,
                  decoration: const InputDecoration(labelText: 'Agent'),
                  items: [
                    for (final installation in installations)
                      DropdownMenuItem(
                        value: installation.id,
                        child: Text(
                          ref
                              .read(agentRegistryProvider)
                              .displayNameFor(installation.agentId),
                        ),
                      ),
                  ],
                  onChanged: (value) => setState(() {
                    _installationId = value;
                    _mode = null;
                  }),
                ),
              const SizedBox(height: Insets.sm),
              _modePicker(installations),
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

  /// The agent's own modes, flat and safest first.
  ///
  /// `AgentPermissionSupport.selections()` rather than a picker per axis: what
  /// the gate reads is the whole selection's rung, and a two-axis agent's seven
  /// distinct combinations are easier to choose between than two menus whose
  /// interaction the reader has to work out.
  Widget _modePicker(List<AgentInstallation> installations) {
    final theme = Theme.of(context);
    final installationId = _installationId;
    if (installationId == null) return const SizedBox.shrink();
    final installation = installations.where((i) => i.id == installationId);
    if (installation.isEmpty) return const SizedBox.shrink();
    final descriptor = ref
        .read(agentRegistryProvider)
        .byId(installation.first.agentId);
    final support = descriptor?.launch.permission;
    if (support == null || !support.isKnown) {
      return Text(
        unknownAgentReason(descriptor?.displayName ?? installation.first.agentId),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      );
    }
    final selections = support.selections();
    final resolved = support.normalise(_mode).canonical;
    return DropdownButtonFormField<String>(
      initialValue: selections.any((s) => s.canonical == resolved)
          ? resolved
          : null,
      decoration: const InputDecoration(
        labelText: 'Permission mode',
        helperText: 'A mode that stops to ask is refused: nobody would be '
            'there to answer.',
      ),
      items: [
        for (final selection in selections)
          DropdownMenuItem(
            value: selection.canonical,
            // Whole selections rather than axes here, so the familiar name is
            // the composed rung's — which is the one the unattended gate
            // reads.
            child: Text(describeSelectionFamiliar(support, selection)),
          ),
      ],
      onChanged: (value) => setState(
        () => _mode = value == null ? null : PermissionSelection.parse(value),
      ),
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
              // what an automation does is authorising the new thing, and the
              // missed-fire sweep counts from that moment rather than claiming
              // occurrences of a rule that no longer exists.
              armedAt: controller.now(),
            )
          : candidate.copyWith(armedAt: controller.now()),
    );
    Navigator.of(context).pop();
  }
}
