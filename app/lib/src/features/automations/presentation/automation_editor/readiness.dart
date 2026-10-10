// Limits, the unattended readiness list, and the dry-run banner.

part of '../automation_editor.dart';

extension _AutomationReadiness on _AutomationEditorState {
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
          _numberField(
            _perHour,
            _draft.trigger == DraftTrigger.webhook
                ? 'At most, runs an hour'
                : 'At most, runs an hour (0 is no limit)',
            (n) => _draft.trigger == DraftTrigger.webhook
                ? _draft.copyWith(
                    callsPerHour: (n ?? 1).clamp(1, kMaxWebhookCallsPerHour),
                  )
                : _draft.copyWith(runsPerHour: (n ?? 0).clamp(0, 10000)),
          ),
          Padding(
            padding: const EdgeInsets.only(top: Insets.sm),
            child: Text(
              'If it is already running there',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: CompactSegmented<AutomationOverlap>(
              key: const ValueKey('automation-overlap'),
              segments: [
                for (final overlap in AutomationOverlap.values)
                  ButtonSegment(value: overlap, label: Text(overlap.label)),
              ],
              selected: _draft.overlap,
              onChanged: (overlap) =>
                  _update(_draft.copyWith(overlap: overlap)),
            ),
          ),
          if (_draft.overlap == AutomationOverlap.queue)
            _numberField(
              _queueLimit,
              'At most, waiting at once',
              (n) => _draft.copyWith(queueLimit: (n ?? 1).clamp(1, 100)),
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
      switch (_perHourValue) {
        0 => 'no limit an hour',
        final n => 'at most $n an hour',
      },
      if (_draft.overlap == AutomationOverlap.merge)
        'later triggers merge'
      else
        'up to ${_draft.queueLimit} waiting',
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
    required AgentInstallation? installation,
    required AgentDescriptor? descriptor,
    required UnattendedRefusal? refusal,
  }) {
    final draft = _draft;
    if (draft.notifyOnly &&
        (draft.trigger == DraftTrigger.event ||
            draft.trigger == DraftTrigger.github)) {
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
          AutomationStepOutcome.waiting => RunOutcome.waitingOnPipeline,
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
