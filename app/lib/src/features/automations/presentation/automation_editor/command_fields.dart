// The first step as a command: its shell, its text, its time limit, and
// running it once.

part of '../automation_editor.dart';

extension _AutomationCommandFields on _AutomationEditorState {
  /// What runs first: an agent or a command, and for an event rule the
  /// session's own ways too. Null when there is nothing to choose.
  Widget? _firstStepPicker() {
    final draft = _draft;
    final commands = ref.watch(commandsOfferedProvider);
    final isEvent =
        draft.trigger == DraftTrigger.event ||
        draft.trigger == DraftTrigger.github;
    if (isEvent) {
      return CompactSegmented<EventFirstStep>(
        key: const ValueKey('automation-first-step'),
        tight: true,
        segments: [
          for (final step in EventFirstStep.values)
            if (step != EventFirstStep.command || commands)
              ButtonSegment(value: step, label: Text(step.short)),
        ],
        selected: draft.firstStep,
        onChanged: (step) => _update(
          step == EventFirstStep.command
              ? _asCommand(_draft.withFirstStep(step))
              : _draft.withFirstStep(step),
        ),
      );
    }
    if (!commands) return null;
    return CompactSegmented<bool>(
      key: const ValueKey('automation-runs'),
      segments: const [
        ButtonSegment(value: false, label: Text('Agent')),
        ButtonSegment(value: true, label: Text('Command')),
      ],
      selected: draft.runsCommand,
      onChanged: (command) => _update(
        command
            ? _asCommand(_draft)
            // An agent runs in a project, never a plain folder.
            : _draft.copyWith(runsCommand: false, place: DraftPlace.project),
      ),
    );
  }

  Widget _firstCommandStep(
    BuildContext context, {
    required Widget? picker,
    required bool windows,
    required String machineName,
    required Automation? probe,
  }) {
    final draft = _draft;
    final shell = draft.effectiveShell;
    final hint = windows
        ? 'In ${draft.shell.label} on $machineName.'
        : 'In your login shell on $machineName.';
    final name = stepEnvironmentName('automation');
    final problem = draft.commandText.trim().isEmpty
        ? null
        : AutomationCommand(text: draft.commandText, shell: shell).refusal;
    return EditorNode(
      key: const ValueKey('automation-command-step'),
      result: _resultFor('agent'),
      title: 'Run a command',
      icon: AppIcons.terminal,
      hint: hint,
      children: [
        ?picker,
        if (windows)
          Wrap(
            spacing: Insets.sm,
            runSpacing: Insets.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Shell', style: Theme.of(context).textTheme.bodySmall),
              CompactSegmented<AutomationShell>(
                key: const ValueKey('automation-shell'),
                segments: [
                  for (final s in const [
                    AutomationShell.powershell,
                    AutomationShell.cmd,
                  ])
                    ButtonSegment(value: s, label: Text(s.label)),
                ],
                selected: draft.shell,
                onChanged: (s) => _update(_draft.copyWith(shell: s)),
              ),
            ],
          ),
        TextField(
          key: const ValueKey('automation-command'),
          controller: _commandText,
          minLines: 2,
          maxLines: 8,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            fontFamily: kMonoFamily,
            fontFamilyFallback: kMonoFallback,
          ),
          decoration: InputDecoration(
            labelText: 'Command',
            alignLabelWithHint: true,
            hintText: windows ? 'Get-Date' : 'git -C ~/notes pull',
          ),
          onChanged: (value) => _update(_draft.copyWith(commandText: value)),
        ),
        if (problem != null)
          _Problem(problem)
        else
          EditorNote(
            'Values reach it as environment variables, never in the '
            'command: ${switch (shell) {
              AutomationShell.powershell => '\$env:$name',
              AutomationShell.cmd => '!$name! (never %$name%, which cmd would run)',
              AutomationShell.login => '"\$$name"',
            }}. A non-zero exit fails the run, and the "if it fails" steps '
            'run. Its output is {{steps.command.output}} for the steps after.',
          ),
        TextField(
          key: const ValueKey('automation-command-limit'),
          controller: _longest,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Time limit, in minutes',
            helperText: 'Still running then, it is stopped and fails.',
          ),
          onChanged: (value) {
            final n = int.tryParse(value.trim());
            _update(
              n == null || n <= 0
                  ? _draft.copyWith(clearMaxRuntime: true)
                  : _draft.copyWith(maxRuntimeMinutes: n),
            );
          },
        ),
        Wrap(
          spacing: Insets.sm,
          runSpacing: Insets.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('automation-command-try'),
              icon: const Icon(AppIcons.play),
              label: Text(_trying ? 'Running…' : 'Run it once'),
              onPressed: _trying || probe == null || draft.missing != null
                  ? null
                  : () => _tryCommand(probe),
            ),
            Text(
              'Runs it now, where it would run. Nothing is saved.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        if (_tried case final tried?) _triedBox(tried),
        if (_tryFailure case final failure?) _Problem(failure),
      ],
    );
  }

  Future<void> _tryCommand(Automation probe) async {
    _redraw(() {
      _trying = true;
      _tried = null;
      _tryFailure = null;
    });
    try {
      final tried = await ref.read(automationsDataProvider).tryCommand(probe);
      if (mounted) _redraw(() => _tried = tried);
    } on Object catch (error) {
      if (mounted) _redraw(() => _tryFailure = 'It did not run: $error');
    } finally {
      if (mounted) _redraw(() => _trying = false);
    }
  }

  Widget _triedBox(AutomationCommandTried tried) {
    final took = durationWords(tried.took);
    return Column(
      key: const ValueKey('automation-command-tried'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StepResultBox(
          outcome: tried.exitCode == 0
              ? RunOutcome.succeeded
              : RunOutcome.failed,
          detail: tried.timedOut
              ? 'Stopped at its time limit, after $took.'
              : 'Exited with ${tried.exitCode} after $took.',
        ),
        if (tried.output.trim().isNotEmpty) CommandOutputBox(tried.output),
      ],
    );
  }
}
