// What starts an automation: the trigger picker and each trigger's fields.

part of '../automation_editor.dart';

extension _AutomationTriggerFields on _AutomationEditorState {
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
            onChanged: (id) =>
                _update(_withGithubRepository(_draft.withCheckout(id))),
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
          DraftTrigger.github => _githubFields(),
          DraftTrigger.once => _onceFields(context),
        },
      ],
    );
  }

  /// [draft] with its GitHub repository read off its checkout's remote, when
  /// it names none yet.
  AutomationDraft _withGithubRepository(AutomationDraft draft) {
    if (draft.github.repository.isNotEmpty) return draft;
    final canonical = _repository(
      ref.read(automationCheckoutsProvider),
    )?.canonicalId;
    final match = RegExp(
      r'^github\.com/([^/]+/[^/]+)$',
    ).firstMatch(canonical ?? '');
    if (match == null) return draft;
    _ghRepo.text = match.group(1)!;
    return draft.copyWith(
      github: draft.github.copyWith(repository: match.group(1)),
    );
  }

  void _putGithub(AutomationGithubTrigger github) =>
      _update(_draft.copyWith(github: github));

  List<Widget> _githubFields() {
    final github = _draft.github;
    return [
      DropdownButtonFormField<GithubTriggerKind>(
        key: const ValueKey('automation-github-kind'),
        initialValue: github.kind,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'When'),
        items: [
          for (final kind in GithubTriggerKind.values)
            DropdownMenuItem(
              value: kind,
              child: Text(kind.label, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (kind) =>
            kind == null ? null : _putGithub(github.copyWith(kind: kind)),
      ),
      TextField(
        key: const ValueKey('automation-github-repo'),
        controller: _ghRepo,
        decoration: const InputDecoration(
          labelText: 'Repository',
          hintText: 'owner/name',
        ),
        onChanged: (value) =>
            _putGithub(github.copyWith(repository: value.trim())),
      ),
      if (github.kind.isPullRequest)
        TextFormField(
          key: const ValueKey('automation-github-branch'),
          initialValue: github.branch,
          decoration: const InputDecoration(
            labelText: 'Branch (empty is any)',
            hintText: 'main, or feature/*',
          ),
          onChanged: (value) =>
              _putGithub(github.copyWith(branch: value.trim())),
        ),
      CompactSegmented<GithubAuthors>(
        key: const ValueKey('automation-github-authors'),
        segments: [
          for (final authors in GithubAuthors.values)
            ButtonSegment(value: authors, label: Text(authors.label)),
        ],
        selected: github.authors,
        onChanged: (authors) => _putGithub(github.copyWith(authors: authors)),
      ),
      if (github.authors == GithubAuthors.listed)
        TextFormField(
          key: const ValueKey('automation-github-logins'),
          initialValue: github.logins.join(', '),
          decoration: const InputDecoration(
            labelText: 'GitHub logins, separated by commas',
          ),
          onChanged: (value) => _putGithub(
            github.copyWith(
              logins: [
                for (final login in value.split(','))
                  if (login.trim().isNotEmpty) login.trim(),
              ],
            ),
          ),
        ),
      TextFormField(
        key: const ValueKey('automation-github-label'),
        initialValue: github.label,
        decoration: InputDecoration(
          labelText: github.kind == GithubTriggerKind.issueLabeled
              ? 'Label'
              : 'Only with this label (optional)',
        ),
        onChanged: (value) => _putGithub(github.copyWith(label: value.trim())),
      ),
      if (github.kind == GithubTriggerKind.issueAssigned)
        TextFormField(
          key: const ValueKey('automation-github-assignee'),
          initialValue: github.assignee,
          decoration: const InputDecoration(
            labelText: 'Assigned to (empty is anyone)',
          ),
          onChanged: (value) =>
              _putGithub(github.copyWith(assignee: value.trim())),
        ),
      TextFormField(
        key: const ValueKey('automation-github-poll'),
        initialValue: '${github.pollEvery.inMinutes}',
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          labelText: 'Look every, in minutes (at least 1)',
        ),
        onChanged: (value) {
          final minutes = int.tryParse(value.trim());
          if (minutes == null || minutes < 1) return;
          _putGithub(github.copyWith(pollSeconds: minutes * 60));
        },
      ),
      const EditorNote(
        'It looks as your gh login. Its first look only notes what is '
        'already there, so turning it on replays nothing. Comments and issue '
        'text reach the agent quoted as someone else\'s words.',
      ),
    ];
  }

  /// A new webhook reads and proposes until somebody says otherwise: its
  /// prompt is a stranger's text.
  AutomationDraft _withTrigger(AutomationDraft draft, DraftTrigger trigger) {
    var next = draft.copyWith(trigger: trigger);
    if (trigger == DraftTrigger.github) next = _withGithubRepository(next);
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
}
