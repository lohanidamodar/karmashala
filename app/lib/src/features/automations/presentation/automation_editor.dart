import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/checks.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_automations/unattended.dart';
import 'package:karmashala_core/verdicts.dart';
import 'package:karmashala_automations/webhooks.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_model_catalog_providers.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/presentation/model_picker.dart';
import '../../settings/presentation/settings_row.dart';

import '../application/automation_draft.dart';
import '../application/automation_editor_state.dart';
import '../application/automation_providers.dart';
import '../application/unattended_preflight.dart';
import '../application/automation_dry_run.dart';
import 'automation_agent_fields.dart';
import 'automation_dry_run_dialog.dart';
import 'automation_run_actions.dart';
import 'automation_run_status.dart';
import 'automation_editor_parts.dart';
import 'project_checks_section.dart' show addProjectCheck;
import 'webhook_parts.dart';

/// **The one editor** for every kind of automation: its name, what starts it,
/// the agent and the steps after it, whether it is ready to run with nobody
/// watching, and its limits. Saving is the authorisation; nothing else arms.
class AutomationEditor extends ConsumerStatefulWidget {
  const AutomationEditor({required this.initial, super.key});

  final AutomationDraft initial;

  @override
  ConsumerState<AutomationEditor> createState() => _AutomationEditorState();
}

class _AutomationEditorState extends ConsumerState<AutomationEditor> {
  late AutomationDraft _draft = widget.initial;
  late final _name = TextEditingController(text: _draft.name);
  late final _prompt = TextEditingController(text: _draft.prompt);
  late final _cron = TextEditingController(text: _draft.cron);
  late final _every = TextEditingController(text: '${_draft.everyMinutes}');
  late final _tell = TextEditingController(
    text: _draft.steps.of(AutomationStepKind.tell)?.text ?? kDefaultTellText,
  );
  late final _notify = TextEditingController(
    text:
        _draft.steps.of(AutomationStepKind.notify)?.text ?? kDefaultNotifyText,
  );
  late final _command = TextEditingController(
    text: _draft.steps.of(AutomationStepKind.command)?.text ?? '',
  );
  late final _hookUrl = TextEditingController(
    text: _draft.steps.of(AutomationStepKind.webhook)?.url ?? '',
  );
  late final _hookBody = TextEditingController(
    text:
        _draft.steps.of(AutomationStepKind.webhook)?.text ??
        kDefaultWebhookBody,
  );
  late final _perHour = TextEditingController(text: '${_draft.callsPerHour}');
  late final _stopAfter = TextEditingController(
    text: '${_draft.stopAfterFailures}',
  );
  late final _longest = TextEditingController(
    text: _draft.maxRuntimeMinutes?.toString() ?? '',
  );
  var _saving = false;
  String? _failure;

  /// Changes not saved yet: Run now runs what is saved, so it waits.
  var _dirty = false;

  /// The last dry run, by card, while nothing changed since.
  Map<String, DryRunStep>? _dry;

  /// The run Run now started, followed here as it goes.
  String? _runId;

  @override
  void dispose() {
    for (final c in [
      _name,
      _prompt,
      _cron,
      _every,
      _tell,
      _notify,
      _command,
      _hookUrl,
      _hookBody,
      _perHour,
      _stopAfter,
      _longest,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _update(AutomationDraft draft) => setState(() {
    _draft = draft;
    _dirty = true;
    _dry = null;
  });

  void _putStep(
    AutomationStepKind kind, {
    AutomationStepWhen? when,
    bool? allowPrivate,
    int? timeoutSeconds,
  }) {
    final existing = _draft.steps.of(kind);
    final text = switch (kind) {
      AutomationStepKind.tell => _tell.text,
      AutomationStepKind.notify => _notify.text,
      AutomationStepKind.command => _command.text,
      AutomationStepKind.webhook => _hookBody.text,
      AutomationStepKind.check => '',
    };
    _update(
      _draft.copyWith(
        steps: _draft.steps.put(
          AutomationStep(
            kind: kind,
            when: when ?? existing?.when ?? _defaultWhen(kind),
            text: text,
            url: kind == AutomationStepKind.webhook ? _hookUrl.text.trim() : '',
            allowPrivate: allowPrivate ?? existing?.allowPrivate ?? false,
            timeoutSeconds: timeoutSeconds ?? existing?.timeoutSeconds,
          ),
        ),
      ),
    );
  }

  static AutomationStepWhen _defaultWhen(AutomationStepKind kind) =>
      switch (kind) {
        AutomationStepKind.tell => AutomationStepWhen.failure,
        AutomationStepKind.notify ||
        AutomationStepKind.webhook => AutomationStepWhen.always,
        AutomationStepKind.check ||
        AutomationStepKind.command => AutomationStepWhen.success,
      };

  Repository? _repository(List<Repository> all) =>
      all.where((r) => r.id == _draft.repositoryId).firstOrNull;

  @override
  Widget build(BuildContext context) {
    final repositories = ref.watch(automationCheckoutsProvider);
    final repository = _repository(repositories);
    final registry = ref.watch(agentRegistryProvider);
    final installations = repository == null
        ? const <AgentInstallation>[]
        : ref
              .watch(agentInstallationsDataProvider)
              .getByEnvironment(repository.path.environmentId);
    final installation = installations
        .where((i) => i.id == _draft.installationId)
        .firstOrNull;
    final descriptor = installation == null
        ? null
        : registry.byId(installation.agentId);
    final now = ref.watch(clockProvider).nowUtc();
    ref.watch(automationsRevisionProvider);
    final checks = repository == null
        ? const <ProjectCheck>[]
        : ref.watch(projectChecksProvider(repository.id));
    final verified =
        repository != null &&
        ref.watch(projectVerificationEnabledProvider(repository.id));
    final probe = _draft.probe(now: now);
    final refusal = probe == null || !probe.startsAgent
        ? null
        : ref.watch(unattendedPreflightProvider).refusalFor(probe);
    final readiness = _readiness(
      repository: repository,
      installation: installation,
      descriptor: descriptor,
      checks: checks,
      verified: verified,
      refusal: refusal,
    );
    final ready = readiness.every((row) => row.ok);
    final missing = _draft.missing;
    final agentName = installation == null
        ? 'the agent'
        : registry.displayNameFor(installation.agentId);
    final summary = probe == null
        ? null
        : automationWords(
            probe,
            checkout: repository?.name ?? 'its checkout',
            agent: agentName,
            now: now,
          );

    return SingleChildScrollView(
      key: const ValueKey('automation-editor'),
      padding: const EdgeInsets.all(Insets.lg),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Chrome.readableWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(
                context,
                missing: missing,
                ready: ready,
                probe: probe,
                checkout: repository?.name ?? 'its checkout',
                agent: agentName,
                checks: [for (final c in checks) c.name],
              ),
              if (_banner(context) case final banner?) ...[
                const SizedBox(height: Insets.sm),
                banner,
              ],
              if (_failure case final failure?) ...[
                const SizedBox(height: Insets.sm),
                DesktopErrorBanner(
                  failure,
                  onDismiss: () => setState(() => _failure = null),
                ),
              ],
              const SizedBox(height: Insets.md),
              _Summary(text: summary),
              const SizedBox(height: Insets.md),
              _starts(context, repositories, repository, now),
              const StepLink(),
              _agentStep(context, installations, descriptor, repository),
              ..._afterSteps(context, checks, repository),
              const StepLink(),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: _addStepButton(),
              ),
              const SizedBox(height: Insets.lg),
              _ReadyCard(rows: readiness),
              const SizedBox(height: Insets.md),
              _limits(context),
              if (!_draft.isNew) ...[
                const SizedBox(height: Insets.lg),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    key: const ValueKey('automation-delete'),
                    style: TextButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                    ),
                    icon: const Icon(AppIcons.trash),
                    label: const Text('Delete automation…'),
                    onPressed: () =>
                        confirmDeleteAutomation(context, ref, _draft.original!),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(
    BuildContext context, {
    required String? missing,
    required bool ready,
    required Automation? probe,
    required String checkout,
    required String agent,
    required List<String> checks,
  }) {
    final theme = Theme.of(context);
    final blocked = missing ?? (ready ? null : kNotReadyTooltip);
    final original = _draft.original;
    final offered = ref.watch(runNowOfferedProvider);
    final cannotRun = !offered
        ? 'This server cannot run an automation on request.'
        : original == null
        ? 'Create it first.'
        : _dirty
        ? 'Save first: Run now runs what is saved.'
        : blocked;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: const ValueKey('automation-editor-back'),
                  icon: const Icon(AppIcons.arrowLeft),
                  label: const Text(
                    'Automations',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onPressed: () =>
                      ref.read(automationEditorProvider.notifier).close(),
                ),
              ),
            ),
            Text(
              _draft.enabled ? 'On' : 'Off',
              style: theme.textTheme.bodySmall,
            ),
            Switch(
              key: const ValueKey('automation-enabled'),
              value: _draft.enabled,
              onChanged: (on) => _update(_draft.copyWith(enabled: on)),
            ),
          ],
        ),
        TextField(
          key: const ValueKey('automation-name'),
          controller: _name,
          style: theme.textTheme.titleMedium,
          decoration: const InputDecoration(
            hintText: 'Name this automation',
            isDense: true,
          ),
          onChanged: (value) => _update(_draft.copyWith(name: value)),
        ),
        const SizedBox(height: Insets.sm),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: Insets.sm,
          runSpacing: Insets.xs,
          children: [
            Tooltip(
              message: cannotRun ?? '',
              child: OutlinedButton(
                key: const ValueKey('automation-run-now'),
                onPressed: cannotRun != null
                    ? null
                    : () async {
                        final run = await runAutomationNow(
                          context,
                          ref,
                          original!,
                        );
                        if (run != null && mounted) {
                          setState(() {
                            _runId = run.id;
                            _dry = null;
                          });
                        }
                      },
                child: const Text('Run now'),
              ),
            ),
            OutlinedButton(
              key: const ValueKey('automation-dry-run'),
              onPressed: probe == null
                  ? null
                  : () => setState(() {
                      _runId = null;
                      _dry = {
                        for (final step in dryRunSteps(
                          probe,
                          checkout: checkout,
                          agent: agent,
                          checks: checks,
                        ))
                          step.key: step,
                      };
                    }),
              child: const Text('Dry run'),
            ),
            Tooltip(
              message: blocked ?? '',
              child: FilledButton(
                key: const ValueKey('automation-save'),
                onPressed: blocked != null || _saving ? null : _save,
                child: Text(_draft.isNew ? 'Create' : 'Save'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _starts(
    BuildContext context,
    List<Repository> repositories,
    Repository? repository,
    DateTime now,
  ) {
    final draft = _draft;
    final probe = draft.probe(now: now);
    final readBack = [
      if (probe != null) triggerWords(probe, now: now),
      if (repository != null) 'in ${repository.name}',
    ].join(', ');
    return EditorNode(
      title: 'Starts',
      icon: AppIcons.lightning,
      children: [
        if (draft.isNew)
          DropdownButtonFormField<String>(
            key: const ValueKey('automation-checkout'),
            initialValue: repository?.id,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Runs in'),
            hint: const Text('Pick a checkout'),
            items: [
              for (final r in repositories)
                DropdownMenuItem(value: r.id, child: Text(r.name)),
            ],
            onChanged: (id) => _update(_draft.withCheckout(id)),
          )
        else
          EditorNote(
            'Runs in ${repository?.name ?? 'a checkout that is gone'}.',
          ),
        CompactSegmented<DraftTrigger>(
          key: const ValueKey('automation-trigger'),
          segments: [
            for (final t in DraftTrigger.values)
              ButtonSegment(value: t, label: Text(t.short)),
          ],
          selected: draft.trigger,
          onChanged: (t) => _update(_withTrigger(_draft, t)),
        ),
        Text(
          readBack.isEmpty ? '…' : readBack,
          key: const ValueKey('automation-readback'),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        ...switch (draft.trigger) {
          DraftTrigger.schedule => _scheduleFields(context, now),
          DraftTrigger.event => _eventFields(),
          DraftTrigger.webhook => _webhookFields(context),
          DraftTrigger.once => _onceFields(context),
        },
      ],
    );
  }

  /// A new webhook reads and proposes until somebody says otherwise: its
  /// prompt is a stranger's text.
  AutomationDraft _withTrigger(AutomationDraft draft, DraftTrigger trigger) {
    var next = draft.copyWith(trigger: trigger);
    if (trigger == DraftTrigger.webhook && draft.isNew) {
      final installation = ref
          .read(agentInstallationsDataProvider)
          .getById(draft.installationId ?? '');
      final support = installation == null
          ? null
          : ref
                .read(agentRegistryProvider)
                .byId(installation.agentId)
                ?.launch
                .permission;
      final readOnly = support == null ? null : readOnlySelection(support);
      next = next.copyWith(prefersReadOnly: true, permissionMode: readOnly);
    }
    return next;
  }

  List<Widget> _scheduleFields(BuildContext context, DateTime now) {
    final draft = _draft;
    return [
      CompactSegmented<DraftScheduleMode>(
        key: const ValueKey('automation-schedule-mode'),
        segments: [
          for (final m in DraftScheduleMode.values)
            ButtonSegment(value: m, label: Text(m.label)),
        ],
        selected: draft.mode,
        onChanged: (m) => _update(_draft.copyWith(mode: m)),
      ),
      ...switch (draft.mode) {
        DraftScheduleMode.time => [
          Wrap(
            spacing: Insets.sm,
            runSpacing: Insets.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('automation-time'),
                icon: const Icon(AppIcons.clock),
                label: Text('At ${clockWords(draft.hour, draft.minute)}'),
                onPressed: () async {
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay(
                      hour: draft.hour,
                      minute: draft.minute,
                    ),
                  );
                  if (picked != null) {
                    _update(
                      _draft.copyWith(hour: picked.hour, minute: picked.minute),
                    );
                  }
                },
              ),
              for (var day = 1; day <= 7; day++)
                FilterChip(
                  key: ValueKey('automation-day-$day'),
                  visualDensity: VisualDensity.compact,
                  showCheckmark: false,
                  label: Text(kDayLetters[day - 1]),
                  selected: draft.days.contains(day),
                  onSelected: (on) => _update(
                    _draft.copyWith(
                      days: on
                          ? {..._draft.days, day}
                          : ({..._draft.days}..remove(day)),
                    ),
                  ),
                ),
            ],
          ),
          const EditorNote('This machine\'s own time.'),
        ],
        DraftScheduleMode.every => [
          TextField(
            key: const ValueKey('automation-every'),
            controller: _every,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Every (minutes)',
              helperText:
                  'Counted from the end of one run, so runs never overlap.',
            ),
            onChanged: (value) => _update(
              _draft.copyWith(everyMinutes: int.tryParse(value.trim()) ?? 0),
            ),
          ),
        ],
        DraftScheduleMode.cron => [
          TextField(
            key: const ValueKey('automation-cron'),
            controller: _cron,
            style: TextStyle(
              fontFamily: kMonoFamily,
              fontFamilyFallback: kMonoFallback,
            ),
            decoration: const InputDecoration(
              labelText: 'Cron: minute hour day month weekday',
            ),
            onChanged: (value) => _update(_draft.copyWith(cron: value)),
          ),
          EditorNote(cronWords(draft.cron, now: now)),
        ],
      },
      if (draft.scheduleProblem case final problem?) _Problem(problem),
      if (draft.mode != DraftScheduleMode.every) _latePolicyField(),
    ];
  }

  Widget _latePolicyField() => DropdownButtonFormField<AutomationLatePolicy>(
    key: const ValueKey('automation-late'),
    initialValue: _draft.latePolicy,
    isExpanded: true,
    decoration: const InputDecoration(
      labelText: 'If Karmashala was closed at that time',
    ),
    items: [
      for (final policy in AutomationLatePolicy.values)
        DropdownMenuItem(value: policy, child: Text(latePolicyWords(policy))),
    ],
    onChanged: (policy) =>
        policy == null ? null : _update(_draft.copyWith(latePolicy: policy)),
  );

  List<Widget> _eventFields() => [
    DropdownButtonFormField<AutomationEventKind>(
      key: const ValueKey('automation-event'),
      initialValue: _draft.eventKind,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'When'),
      items: [
        for (final kind in AutomationEventKind.values)
          DropdownMenuItem(value: kind, child: Text(kind.label)),
      ],
      onChanged: (kind) =>
          kind == null ? null : _update(_draft.copyWith(eventKind: kind)),
    ),
    const EditorNote(
      'Only sessions in this checkout. It never reacts to a run it started '
      'itself, runs at most once a second, and never takes your focus.',
    ),
  ];

  List<Widget> _webhookFields(BuildContext context) => [
    if (_draft.original case final original? when original.isWebhook)
      WebhookUrlRow(automation: original)
    else
      const EditorNote('Its URL and secret appear once you create it.'),
    SettingsSwitchRow(
      label: 'Only accept signed calls',
      help:
          'GitHub\'s X-Hub-Signature-256 works. Off, the URL alone lets '
          'anyone start a run.',
      value: _draft.requireSignature,
      onChanged: (on) => _update(_draft.copyWith(requireSignature: on)),
    ),
    const EditorNote(
      'The prompt can name fields of the call\'s JSON body, like '
      '{{issue.title}}. Only what it names reaches the agent, quoted as data.',
    ),
    if (_draft.original case final original? when original.isWebhook)
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: OutlinedButton(
          key: const ValueKey('automation-deliveries'),
          onPressed: () => WebhookDeliveriesDialog.show(context, original),
          child: const Text('Deliveries'),
        ),
      ),
  ];

  List<Widget> _onceFields(BuildContext context) => [
    Row(
      children: [
        Expanded(
          child: Text(
            _draft.once == null
                ? 'No time picked yet.'
                : momentWords(_draft.once!),
          ),
        ),
        TextButton(
          key: const ValueKey('automation-once'),
          onPressed: () => _pickMoment(context),
          child: const Text('Pick a time'),
        ),
      ],
    ),
    _latePolicyField(),
  ];

  Future<void> _pickMoment(BuildContext context) async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _draft.once ?? now,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 366)),
    );
    if (date == null || !context.mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_draft.once ?? now),
    );
    if (time == null) return;
    _update(
      _draft.copyWith(
        once: DateTime(date.year, date.month, date.day, time.hour, time.minute),
      ),
    );
  }

  Widget _agentStep(
    BuildContext context,
    List<AgentInstallation> installations,
    AgentDescriptor? descriptor,
    Repository? repository,
  ) {
    final draft = _draft;
    final isEvent = draft.trigger == DraftTrigger.event;
    final selected = installations
        .where((i) => i.id == draft.installationId)
        .firstOrNull;
    final first = isEvent ? draft.firstStep : EventFirstStep.agent;
    return EditorNode(
      result: _resultFor('agent'),
      title: first.label,
      icon: AppIcons.robot,
      hint: switch (first) {
        EventFirstStep.agent => 'A new session with your prompt.',
        EventFirstStep.tell => 'The session the event came from.',
        EventFirstStep.nothing => 'Only the steps below run.',
      },
      children: [
        if (isEvent)
          CompactSegmented<EventFirstStep>(
            key: const ValueKey('automation-first-step'),
            segments: [
              for (final step in EventFirstStep.values)
                ButtonSegment(value: step, label: Text(step.short)),
            ],
            selected: first,
            onChanged: (step) => _update(_draft.withFirstStep(step)),
          ),
        if (draft.namesAgent) ...[
          if (repository == null)
            const EditorNote('Pick a checkout first.')
          else
            AutomationAgentField(
              installations: installations,
              selectedId: draft.installationId,
              displayNameFor: ref.watch(agentRegistryProvider).displayNameFor,
              onChanged: (id) {
                final picked = installations.where((i) => i.id == id).first;
                final support = ref
                    .read(agentRegistryProvider)
                    .byId(picked.agentId)
                    ?.launch
                    .permission;
                _update(
                  _draft.copyWith(
                    installationId: id,
                    clearModel: true,
                    permissionMode: draft.prefersReadOnly && support != null
                        ? readOnlySelection(support)
                        : null,
                    clearPermission: !draft.prefersReadOnly || support == null,
                  ),
                );
              },
            ),
          if (selected != null && descriptor != null) ...[
            Row(
              children: [
                Text('Model', style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(width: Insets.sm),
                ModelPicker(
                  options: modelOptionsFor(
                    descriptor,
                    current: draft.modelId,
                    support: ref.watch(
                      agentModelSupportProvider(descriptor.id),
                    ),
                  ),
                  selected: draft.modelId,
                  onChanged: (choice) => _update(
                    _draft.copyWith(
                      modelId: choice.modelId,
                      clearModel: choice.modelId == null,
                    ),
                  ),
                ),
              ],
            ),
            AutomationPermissionModeField(
              agentName: descriptor.displayName,
              support: descriptor.launch.permission,
              value: draft.permissionMode,
              onChanged: (mode) => _update(
                _draft.copyWith(
                  permissionMode: mode,
                  clearPermission: mode == null,
                ),
              ),
            ),
          ],
          SettingsSwitchRow(
            label: 'In a worktree of its own',
            help: 'Your checkout stays untouched while it runs.',
            value: draft.worktree,
            onChanged: (on) => _update(_draft.copyWith(worktree: on)),
          ),
        ],
        if (first != EventFirstStep.nothing)
          TextField(
            key: const ValueKey('automation-prompt'),
            controller: _prompt,
            minLines: 3,
            maxLines: 8,
            decoration: InputDecoration(
              labelText: draft.namesAgent
                  ? 'What the agent is told'
                  : 'What the session is told',
              hintText: 'Run the checks and fix what broke.',
            ),
            onChanged: (value) => _update(_draft.copyWith(prompt: value)),
          ),
        if (draft.trigger == DraftTrigger.webhook) _webhookFieldsRead(draft),
      ],
    );
  }

  Widget _webhookFieldsRead(AutomationDraft draft) {
    final refusal = webhookTemplateRefusal(draft.prompt);
    if (refusal != null && draft.prompt.trim().isNotEmpty) {
      return _Problem(refusal);
    }
    final fields = webhookTemplateFields(draft.prompt);
    return EditorNote(
      fields.isEmpty
          ? 'It reads no field of the call; name one like {{issue.title}}.'
          : 'Reads ${fields.join(', ')}',
    );
  }

  List<Widget> _afterSteps(
    BuildContext context,
    List<ProjectCheck> checks,
    Repository? repository,
  ) {
    final widgets = <Widget>[];
    for (final step in _draft.steps.after) {
      final failure =
          step.when == AutomationStepWhen.failure &&
          step.kind != AutomationStepKind.check;
      final rail = failure ? failureRail(context) : null;
      widgets.add(
        StepLink(
          label: step.kind == AutomationStepKind.check
              ? null
              : switch (step.when) {
                  AutomationStepWhen.failure => 'if it fails',
                  AutomationStepWhen.always => 'always',
                  AutomationStepWhen.success => 'if it succeeded',
                },
          color: rail,
        ),
      );
      widgets.add(switch (step.kind) {
        AutomationStepKind.check => _checkStep(context, checks, repository),
        AutomationStepKind.command => _commandStep(step, rail),
        AutomationStepKind.webhook => _webhookStep(step, rail),
        AutomationStepKind.tell => _messageStep(
          context,
          step,
          controller: _tell,
          title: 'Tell the agent',
          hint: 'Send its session a message.',
          icon: AppIcons.arrowUDownLeft,
          label: 'Message to the agent',
          rail: rail,
        ),
        AutomationStepKind.notify => _messageStep(
          context,
          step,
          controller: _notify,
          title: 'Notify me',
          hint: 'On this device and the phone.',
          icon: AppIcons.bellSimple,
          label: 'Notification',
          rail: rail,
        ),
      });
    }
    return widgets;
  }

  Widget _removeButton(AutomationStepKind kind) => IconButton(
    key: ValueKey('automation-remove-${kind.storedName}'),
    tooltip: 'Remove this step',
    icon: const Icon(AppIcons.x),
    onPressed: () =>
        _update(_draft.copyWith(steps: _draft.steps.without(kind))),
  );

  Widget _checkStep(
    BuildContext context,
    List<ProjectCheck> checks,
    Repository? repository,
  ) => EditorNode(
    result: _resultFor(AutomationStepKind.check.storedName),
    title: 'Check the result',
    icon: AppIcons.listChecks,
    hint: 'Runs the checkout\'s checks on what the agent did.',
    trailing: [_removeButton(AutomationStepKind.check)],
    children: [
      if (checks.isEmpty)
        Wrap(
          spacing: Insets.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            EditorNote(
              '${repository?.name ?? 'This checkout'} has no checks yet.',
            ),
            if (repository != null)
              OutlinedButton(
                onPressed: () =>
                    addProjectCheck(context, ref, repository, turnOn: true),
                child: const Text('Add a check'),
              ),
          ],
        )
      else
        EditorNote(
          'Runs ${checks.map((c) => c.name).join(', ')}. The run passes only '
          'if every check does.',
        ),
    ],
  );

  Widget _messageStep(
    BuildContext context,
    AutomationStep step, {
    required TextEditingController controller,
    required String title,
    required String hint,
    required IconData icon,
    required String label,
    required Color? rail,
  }) => EditorNode(
    result: _resultFor(step.kind.storedName),
    title: title,
    icon: icon,
    hint: hint,
    rail: rail,
    trailing: [_removeButton(step.kind)],
    children: [
      DropdownButtonFormField<AutomationStepWhen>(
        key: ValueKey('automation-when-${step.kind.storedName}'),
        initialValue: step.when,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Runs'),
        items: [
          for (final when in AutomationStepWhen.values)
            DropdownMenuItem(value: when, child: Text(when.label)),
        ],
        onChanged: (when) =>
            when == null ? null : _putStep(step.kind, when: when),
      ),
      TextField(
        key: ValueKey('automation-text-${step.kind.storedName}'),
        controller: controller,
        minLines: 2,
        maxLines: 6,
        decoration: InputDecoration(labelText: label),
        onChanged: (_) => _putStep(step.kind),
      ),
      VariableChips(
        names: kStepVariables.keys.toList(),
        controller: controller,
        onChanged: () => _putStep(step.kind),
      ),
    ],
  );

  Widget _whenField(AutomationStep step) =>
      DropdownButtonFormField<AutomationStepWhen>(
        key: ValueKey('automation-when-${step.kind.storedName}'),
        initialValue: step.when,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Runs'),
        items: [
          for (final when in AutomationStepWhen.values)
            DropdownMenuItem(value: when, child: Text(when.label)),
        ],
        onChanged: (when) =>
            when == null ? null : _putStep(step.kind, when: when),
      );

  Widget _timeoutField(AutomationStep step, {required bool minutes}) =>
      TextFormField(
        key: ValueKey('automation-timeout-${step.kind.storedName}'),
        initialValue: minutes
            ? '${step.timeout.inMinutes}'
            : '${step.timeout.inSeconds}',
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: minutes
              ? 'Time limit, in minutes'
              : 'Time limit, in seconds',
        ),
        onChanged: (value) {
          final n = int.tryParse(value.trim());
          if (n == null || n <= 0) return;
          _putStep(step.kind, timeoutSeconds: minutes ? n * 60 : n);
        },
      );

  Widget _commandStep(AutomationStep step, Color? rail) => EditorNode(
    result: _resultFor(step.kind.storedName),
    title: 'Run a command',
    icon: AppIcons.terminal,
    hint: 'In the run\'s worktree or checkout, only where checks are on.',
    rail: rail,
    trailing: [_removeButton(step.kind)],
    children: [
      _whenField(step),
      TextField(
        key: const ValueKey('automation-text-command'),
        controller: _command,
        minLines: 1,
        maxLines: 4,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          fontFamily: kMonoFamily,
          fontFamilyFallback: kMonoFallback,
        ),
        decoration: const InputDecoration(labelText: 'Command'),
        onChanged: (_) => _putStep(step.kind),
      ),
      if (step.refusal case final why? when _command.text.isNotEmpty)
        _Problem(why)
      else
        EditorNote(
          'Values reach it as environment variables, never in the command: '
          '"\$${stepEnvironmentName('github.pr.branch')}" in sh, '
          '\$env:${stepEnvironmentName('github.pr.branch')} in PowerShell. '
          'Its output and exit code are {{steps.command.output}} and '
          '{{steps.command.exit_code}} for the steps after.',
        ),
      _timeoutField(step, minutes: true),
    ],
  );

  Widget _webhookStep(AutomationStep step, Color? rail) => EditorNode(
    result: _resultFor(step.kind.storedName),
    title: 'Call a webhook',
    icon: AppIcons.webhooksLogo,
    hint: 'POSTs JSON, with an Idempotency-Key per run.',
    rail: rail,
    trailing: [_removeButton(step.kind)],
    children: [
      _whenField(step),
      TextField(
        key: const ValueKey('automation-url-webhook'),
        controller: _hookUrl,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(labelText: 'URL'),
        onChanged: (_) => _putStep(step.kind),
      ),
      TextField(
        key: const ValueKey('automation-text-webhook'),
        controller: _hookBody,
        minLines: 2,
        maxLines: 6,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          fontFamily: kMonoFamily,
          fontFamilyFallback: kMonoFallback,
        ),
        decoration: const InputDecoration(labelText: 'Body'),
        onChanged: (_) => _putStep(step.kind),
      ),
      VariableChips(
        names: kStepVariables.keys.toList(),
        controller: _hookBody,
        onChanged: () => _putStep(step.kind),
      ),
      if (step.refusal case final why? when _hookUrl.text.isNotEmpty)
        _Problem(why)
      else
        const EditorNote(
          'Values are JSON-escaped where they stand, so put each inside a '
          'string.',
        ),
      SettingsSwitchRow(
        key: const ValueKey('automation-private-webhook'),
        label: 'Allow addresses on my network',
        help:
            'Off, private, loopback and link-local addresses are refused, so '
            'a run cannot reach into your network.',
        value: step.allowPrivate,
        onChanged: (on) => _putStep(step.kind, allowPrivate: on),
      ),
      _timeoutField(step, minutes: false),
    ],
  );

  Widget _addStepButton() {
    final missing = [
      for (final kind in AutomationStepKind.values)
        if (_draft.steps.of(kind) == null) kind,
    ];
    return PopupMenuButton<AutomationStepKind>(
      key: const ValueKey('automation-add-step'),
      tooltip: 'Add a step',
      enabled: missing.isNotEmpty,
      onSelected: (kind) => _putStep(kind),
      itemBuilder: (_) => [
        for (final kind in missing)
          PopupMenuItem(value: kind, child: Text(kind.label)),
      ],
      child: const Padding(
        padding: EdgeInsets.symmetric(
          horizontal: Insets.sm,
          vertical: Insets.xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(AppIcons.plus),
            SizedBox(width: Insets.xs),
            Text('Add a step'),
          ],
        ),
      ),
    );
  }

  Widget _limits(BuildContext context) => EditorNode(
    title: 'Limits',
    icon: AppIcons.slidersHorizontal,
    children: [
      ExpansionTile(
        key: const ValueKey('automation-limits'),
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        shape: const Border(),
        collapsedShape: const Border(),
        title: Text(
          _limitsWords(),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        children: [
          if (_draft.trigger == DraftTrigger.webhook)
            _numberField(
              _perHour,
              'At most, runs an hour',
              (n) => _draft.copyWith(
                callsPerHour: (n ?? 1).clamp(1, kMaxWebhookCallsPerHour),
              ),
            ),
          _numberField(
            _stopAfter,
            'Pause after failures in a row (0 never pauses)',
            (n) => _draft.copyWith(stopAfterFailures: n ?? 0),
          ),
          _numberField(
            _longest,
            'Longest run, in minutes (empty: no limit)',
            (n) => n == null || n <= 0
                ? _draft.copyWith(clearMaxRuntime: true)
                : _draft.copyWith(maxRuntimeMinutes: n),
          ),
          const SizedBox(height: Insets.sm),
          const EditorNote(
            'A run that would break a limit is not started, and shows in '
            'Runs with the reason.',
          ),
        ],
      ),
    ],
  );

  String _limitsWords() {
    final parts = [
      if (_draft.trigger == DraftTrigger.webhook)
        'at most ${_draft.callsPerHour} an hour',
      _draft.stopAfterFailures == 0
          ? 'never pauses itself'
          : 'pauses after ${_draft.stopAfterFailures} failures in a row',
      _draft.maxRuntimeMinutes == null
          ? 'no longest run'
          : 'runs at most ${_draft.maxRuntimeMinutes} min',
    ];
    final text = parts.join(' · ');
    return '${text[0].toUpperCase()}${text.substring(1)}';
  }

  Widget _numberField(
    TextEditingController controller,
    String label,
    AutomationDraft Function(int? value) apply,
  ) => Padding(
    padding: const EdgeInsets.only(top: Insets.sm),
    child: TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(labelText: label),
      onChanged: (value) => _update(apply(int.tryParse(value.trim()))),
    ),
  );

  List<ReadyRow> _readiness({
    required Repository? repository,
    required AgentInstallation? installation,
    required AgentDescriptor? descriptor,
    required List<ProjectCheck> checks,
    required bool verified,
    required UnattendedRefusal? refusal,
  }) {
    final draft = _draft;
    if (draft.notifyOnly && draft.trigger == DraftTrigger.event) {
      return const [
        ReadyRow(true, 'It starts nothing, so nothing can go wrong.'),
      ];
    }
    if (!draft.namesAgent) {
      return const [
        ReadyRow(
          true,
          'It tells a session that is already open, under that session\'s '
          'own permissions.',
        ),
      ];
    }
    final checkout = repository?.name ?? 'This checkout';
    final rows = <ReadyRow>[];
    final support = descriptor?.launch.permission;
    final risk = support?.riskOf(
      support.resolveStored(draft.permissionMode?.canonical),
    );
    if (installation == null || descriptor == null) {
      rows.add(const ReadyRow(false, 'Pick the agent it starts.'));
    } else if (refusal?.kind == UnattendedRefusalKind.permissionModeUnknown) {
      rows.add(ReadyRow(false, refusal!.reason));
    } else if (risk != null && permissionModeCanPrompt(risk)) {
      rows.add(
        ReadyRow(
          false,
          '"${describeSelectionFamiliar(support!, draft.permissionMode)}" '
          'stops to ask, and nobody would be there. Pick one that does not.',
        ),
      );
    } else {
      rows.add(
        ReadyRow(
          true,
          '${descriptor.displayName} runs as '
          '"${describeSelectionFamiliar(support!, draft.permissionMode)}", so '
          'it never stops to ask.',
        ),
      );
    }
    if (risk == PermissionRisk.readOnly) {
      rows.add(
        const ReadyRow(true, 'Read-only, so there is nothing to check.'),
      );
    } else if (checks.isEmpty) {
      rows.add(
        ReadyRow(
          false,
          '$checkout has no check yet, and nobody is there to judge the work.',
          action: repository == null ? null : 'Add a check',
          onAction: repository == null
              ? null
              : () => addProjectCheck(context, ref, repository, turnOn: true),
        ),
      );
    } else if (!verified) {
      rows.add(
        ReadyRow(
          false,
          'Checks are off for $checkout.',
          action: 'Turn them on',
          onAction: () => ref
              .read(automationControllerProvider)
              .setVerificationEnabled(repository!.id, enabled: true),
        ),
      );
    } else if (!draft.steps.checks) {
      rows.add(
        ReadyRow(
          false,
          'Nothing checks what the agent did.',
          action: 'Add "Check the result"',
          onAction: () => _putStep(AutomationStepKind.check),
        ),
      );
    } else {
      rows.add(
        ReadyRow(
          true,
          'A check judges the result: ${checks.map((c) => c.name).join(', ')}.',
        ),
      );
    }
    if (refusal != null &&
        const {
          UnattendedRefusalKind.agentUnavailable,
          UnattendedRefusalKind.environmentUnnamed,
          UnattendedRefusalKind.environmentUnreachable,
        }.contains(refusal.kind)) {
      rows.add(ReadyRow(false, refusal.reason));
    }
    rows.add(
      const ReadyRow(
        true,
        'A checkpoint is taken first, so a run can be undone.',
      ),
    );
    return rows;
  }

  /// The dry run's line or the live run's outcome for card [key], or null.
  Widget? _resultFor(String key) {
    if (_dry?[key] case final step?) {
      return StepResultBox(outcome: RunOutcome.planned, detail: step.would);
    }
    final run = _liveRun();
    if (run == null) return null;
    final checks = ref.read(automationsDataProvider).checksFor(run.id);
    if (key == 'agent') {
      return StepResultBox(
        outcome: runOutcome(run, const []),
        detail: run.reason,
      );
    }
    if (key == AutomationStepKind.check.storedName) {
      if (checks.isEmpty) return null;
      return StepResultBox(
        outcome: checks.any((c) => c.verdict != VerificationVerdict.pass)
            ? RunOutcome.failed
            : RunOutcome.succeeded,
        detail: [
          for (final c in checks) '${c.verdict.label} · ${c.name}',
        ].join('\n'),
      );
    }
    for (final step in run.stepResults) {
      if (step.kind.storedName != key) continue;
      return StepResultBox(
        outcome: switch (step.outcome) {
          AutomationStepOutcome.done => RunOutcome.succeeded,
          AutomationStepOutcome.failed => RunOutcome.failed,
          AutomationStepOutcome.skipped => RunOutcome.unknown,
        },
        detail: step.detail,
      );
    }
    return null;
  }

  AutomationRun? _liveRun() {
    final id = _runId;
    if (id == null) return null;
    ref.watch(automationsRevisionProvider);
    return ref.read(automationsDataProvider).runById(id);
  }

  Widget? _banner(BuildContext context) {
    final String text;
    if (_dry != null) {
      text = 'Dry run: nothing was started. Each step shows what it would do.';
    } else if (_liveRun() case final run?) {
      text = switch (runOutcome(
        run,
        ref.read(automationsDataProvider).checksFor(run.id),
      )) {
        RunOutcome.running => 'Running now. Each step fills in as it goes.',
        RunOutcome.queued => 'Waiting for its checkout to come free.',
        RunOutcome.checking => 'The agent is done; checking the result.',
        RunOutcome.succeeded => 'Ran now: every step went as it should.',
        RunOutcome.failed => 'Ran now, and something failed. See each step.',
        _ => 'Ran now: ${run.reason}',
      };
    } else {
      return null;
    }
    return Row(
      key: const ValueKey('automation-banner'),
      children: [
        Expanded(
          child: Text(text, style: Theme.of(context).textTheme.bodySmall),
        ),
        if (_runId != null)
          TextButton(
            onPressed: () => showRunsOf(ref, _draft.original?.id),
            child: const Text('See it in Runs'),
          ),
        if (_dry != null && _draft.trigger == DraftTrigger.event)
          TextButton(
            key: const ValueKey('automation-dry-run-session'),
            onPressed: () {
              final probe = _draft.probe(now: ref.read(clockProvider).nowUtc());
              if (probe != null) AutomationDryRunDialog.show(context, probe);
            },
            child: const Text('Try it on a session…'),
          ),
      ],
    );
  }

  Future<void> _save() async {
    final controller = ref.read(automationControllerProvider);
    final data = ref.read(automationsDataProvider);
    final automation = _draft.toAutomation(
      id: controller.newId(),
      now: controller.now(),
    );
    if (automation == null) return;
    final created = _draft.isNew;
    setState(() {
      _saving = true;
      _failure = null;
    });
    try {
      final stored = await data.saveAndWait(automation);
      final issued = created && stored.isWebhook
          ? await data.rotateWebhook(stored.id)
          : null;
      if (!mounted) return;
      setState(() {
        _saving = false;
        _dirty = false;
        _draft = AutomationDraft.from(stored);
      });
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(created ? 'Created' : 'Saved')));
      if (issued != null) await WebhookSecretDialog.show(context, issued);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _failure = '$error';
        });
      }
    }
  }
}

/// What the Create button says while the readiness list has a cross.
const kNotReadyTooltip = 'Fix what is listed under Ready to run unattended.';

/// The tell step's text until someone writes their own.
const kDefaultTellText =
    'The checks failed:\n\n{{steps.check.output}}\n\nFix them.';

/// The notify step's text until someone writes their own.
const kDefaultNotifyText = '{{automation}} in {{project}}: {{run.status}}';

/// The webhook step's body until someone writes their own.
const kDefaultWebhookBody =
    '{"automation": "{{automation}}", "status": "{{run.status}}"}';

const kDayLetters = ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'];

/// The late policy, said for the editor's question.
String latePolicyWords(AutomationLatePolicy policy) => switch (policy) {
  AutomationLatePolicy.run => 'Run it when Karmashala opens, however late',
  AutomationLatePolicy.ask => 'Run it if it is less than an hour late',
  AutomationLatePolicy.skip => 'Skip it, and show it as missed',
};

/// The agent's own read-only mode, or null when it has none.
PermissionSelection? readOnlySelection(AgentPermissionSupport support) {
  if (!support.isKnown) return null;
  for (final selection in support.selections()) {
    if (support.riskOf(selection) == PermissionRisk.readOnly) return selection;
  }
  return null;
}

/// One line of "Ready to run unattended".
class ReadyRow {
  const ReadyRow(this.ok, this.text, {this.action, this.onAction});

  final bool ok;
  final String text;
  final String? action;
  final VoidCallback? onAction;
}

class _ReadyCard extends StatelessWidget {
  const _ReadyCard({required this.rows});

  final List<ReadyRow> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    return EditorNode(
      key: const ValueKey('automation-ready'),
      title: 'Ready to run unattended',
      icon: AppIcons.checkCircle,
      children: [
        for (final row in rows)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                row.ok ? AppIcons.check : AppIcons.x,
                size: Touch.iconSmall,
                color: row.ok ? semantic.idle : semantic.failure,
                semanticLabel: row.ok ? 'Ready' : 'Not ready',
              ),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Wrap(
                  spacing: Insets.sm,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(row.text, style: theme.textTheme.bodySmall),
                    if (row.action case final action?)
                      TextButton(onPressed: row.onAction, child: Text(action)),
                  ],
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.text});

  final String? text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text.rich(
      key: const ValueKey('automation-summary'),
      TextSpan(
        children: [
          TextSpan(
            text: 'In plain words: ',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          TextSpan(text: text ?? 'fill in what starts it and the agent.'),
        ],
      ),
      style: theme.textTheme.bodyMedium,
    );
  }
}

class _Problem extends StatelessWidget {
  const _Problem(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.error,
      ),
    );
  }
}

/// Asks before deleting, and offers to pause instead.
Future<void> confirmDeleteAutomation(
  BuildContext context,
  WidgetRef ref,
  Automation automation,
) async {
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: DesktopDialogTitle(
        icon: AppIcons.trash,
        title: 'Delete "${automation.name}"?',
      ),
      content: const BoundedDialogContent(
        width: DialogWidth.narrow,
        child: Text(
          'It won\'t run again, and its steps are forgotten. Its runs stay '
          'in Runs. To stop it for now and keep it, pause it instead.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Keep it'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop('pause'),
          child: const Text('Pause instead'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: () => Navigator.of(context).pop('delete'),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  final controller = ref.read(automationControllerProvider);
  switch (choice) {
    case 'pause':
      controller.setEnabled(automation.id, enabled: false);
    case 'delete':
      controller.delete(automation.id);
      ref.read(automationEditorProvider.notifier).close();
  }
}
