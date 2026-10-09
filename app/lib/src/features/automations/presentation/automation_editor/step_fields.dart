// The agent step and the steps after it.

part of '../automation_editor.dart';

extension _AutomationStepFields on _AutomationEditorState {
  Widget _agentStep(
    BuildContext context,
    List<AgentInstallation> installations,
    AgentDescriptor? descriptor,
    Repository? repository,
  ) {
    final draft = _draft;
    final isGithub = draft.trigger == DraftTrigger.github;
    final isEvent = draft.trigger == DraftTrigger.event || isGithub;
    final selected = installations
        .where((i) => i.id == draft.installationId)
        .firstOrNull;
    final first = isEvent ? draft.firstStep : EventFirstStep.agent;
    return EditorNode(
      result: _resultFor('agent'),
      title: first.label,
      icon: AppIcons.robot,
      hint: switch (first) {
        EventFirstStep.agent when isGithub && draft.github.kind.isPullRequest =>
          'A new session in a worktree on the pull request\'s branch.',
        EventFirstStep.agent => 'A new session with your prompt.',
        EventFirstStep.tell when isGithub =>
          'The session on the pull request\'s branch, or a new agent there '
              'when none is.',
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
                Flexible(
                  child: ModelPicker(
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
        if (isGithub && first != EventFirstStep.nothing)
          VariableChips(
            names: kGithubVariables.keys.toList(),
            controller: _prompt,
            onChanged: () => _update(_draft.copyWith(prompt: _prompt.text)),
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

  List<Widget> _afterSteps(BuildContext context) {
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
        AutomationStepKind.check => _checkStep(step),
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

  Widget _checkStep(AutomationStep step) => EditorNode(
    result: _resultFor(AutomationStepKind.check.storedName),
    title: 'Check the result',
    icon: AppIcons.listChecks,
    hint: 'Optional. Runs on what the agent did.',
    trailing: [_removeButton(AutomationStepKind.check)],
    children: [
      TextField(
        key: const ValueKey('automation-text-check'),
        controller: _checkCommand,
        minLines: 1,
        maxLines: 4,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          fontFamily: kMonoFamily,
          fontFamilyFallback: kMonoFallback,
        ),
        decoration: const InputDecoration(
          labelText: 'Command',
          hintText: 'flutter test',
        ),
        onChanged: (_) => _putStep(AutomationStepKind.check),
      ),
      TextField(
        key: const ValueKey('automation-name-check'),
        controller: _checkName,
        decoration: const InputDecoration(
          labelText: 'Name (optional)',
          hintText: 'the tests',
        ),
        onChanged: (_) => _putStep(AutomationStepKind.check),
      ),
      if (step.refusal case final why?)
        _Problem(why)
      else
        const EditorNote(
          'One command a line. A non-zero exit fails the run, and the '
          '"if it fails" steps run. A check still running at its time limit '
          'is stopped, with everything it started, and fails.',
        ),
      _timeoutField(step, minutes: true),
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
        names: _stepVariableNames,
        controller: controller,
        onChanged: () => _putStep(step.kind),
      ),
    ],
  );

  List<String> get _stepVariableNames => [
    ...kStepVariables.keys,
    if (_draft.trigger == DraftTrigger.github) ...kGithubVariables.keys,
  ];

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
    hint: 'In the run\'s worktree or checkout.',
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
        names: _stepVariableNames,
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
}
