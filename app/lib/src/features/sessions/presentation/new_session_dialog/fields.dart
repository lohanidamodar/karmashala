// The dialog's choice fields: terminal, parent, keep-here and the work place.

part of '../new_session_dialog.dart';

// `State.setState` is `@protected`, which covers a subclass and not an extension
// splitting that subclass's own body inside its own library.
// ignore_for_file: invalid_use_of_protected_member

extension _NewSessionFields on _NewSessionDialogState {
  Widget _terminalPicker() {
    final terminals = ref.watch(availableSystemTerminalsProvider);
    return terminals.when(
      loading: () => const Padding(
        padding: EdgeInsets.only(top: Insets.md),
        child: LinearProgressIndicator(),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.only(top: Insets.md),
        child: Text('Could not detect terminals: $e'),
      ),
      data: (list) {
        if (list.isEmpty) {
          return const Padding(
            padding: EdgeInsets.only(top: Insets.md),
            child: Text('No external terminals were found on PATH.'),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(top: Insets.md),
          child: DropdownButtonFormField<SystemTerminal>(
            initialValue: _terminalFrom(list),
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Terminal'),
            items: [
              for (final t in list)
                DropdownMenuItem(
                  value: t,
                  child: Text(t.label, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) => setState(() => _terminal = v),
          ),
        );
      },
    );
  }

  /// No agent is installed where the session would run: says where, and offers
  /// to look again. Wraps rather than squeezing the sentence beside the button
  /// at the dialog's narrowest.
  Widget _noAgents(Repository? checkout) => Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: Insets.sm,
    children: [
      Text(
        checkout == null
            ? 'No agent installations found yet.'
            : 'No agent is installed in '
                  '${ref.watch(environmentLabelForIdProvider(checkout.path.environmentId))} yet.',
      ),
      TextButton(
        onPressed: _busy ? null : _discoverAgents,
        child: const Text('Discover agents'),
      ),
    ],
  );

  /// The parent the session starts under: ticked, and still allowed one more
  /// level. Null starts it on its own.
  String? _linkedParent() {
    final parent = widget.parentSessionId;
    if (parent == null || !_linkParent) return null;
    return _parentDepth(parent).isAllowed ? parent : null;
  }

  SessionDepth _parentDepth(String parentId) =>
      ref.read(sessionLauncherProvider).depthForChildOf(parentId);

  /// **"Link to …"**: whether the session starts as the current one's
  /// sub-session — under it on the dashboard, able to report back — or on its
  /// own. Said plainly, and withdrawn where one more level is refused.
  Widget _parentChoice(String parentId) {
    final title =
        ref.watch(sessionsDataProvider).getById(parentId)?.title ??
        'this session';
    final depth = _parentDepth(parentId);
    final theme = Theme.of(context);
    return CheckboxListTile(
      key: const ValueKey('new-session-link-parent'),
      value: _linkParent && depth.isAllowed,
      dense: true,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      visualDensity: UiDensity.of(context).controlDensity,
      title: Text('Link to "$title"'),
      subtitle: Text(
        !depth.isAllowed
            ? 'Sessions nest at most ${SessionDepth.maxDepth} levels deep, so '
                  'this one starts on its own.'
            : _linkParent
            ? 'A sub-session: it sits under that session and can report back '
                  'to it. Detach it later to let it go.'
            : 'A session of its own: nothing goes between the two.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      onChanged: _busy || !depth.isAllowed
          ? null
          : (value) => setState(() => _linkParent = value ?? false),
    );
  }

  /// "Keep working here": start it at the server and open no tab.
  Widget _keepHereChoice() => CheckboxListTile(
    key: const ValueKey('new-session-keep-here'),
    value: _keepHere,
    dense: true,
    contentPadding: EdgeInsets.zero,
    controlAffinity: ListTileControlAffinity.leading,
    visualDensity: UiDensity.of(context).controlDensity,
    title: const Text("Keep working here (don't open a tab)"),
    onChanged: _busy
        ? null
        : (value) => setState(() => _keepHere = value ?? false),
  );

  /// In the app or in a terminal of its own, and in the checkout, a new
  /// worktree, or one that exists (spec §5). Worktrees are offered for both
  /// surfaces: they exist before the agent starts, so its window is moot.
  /// Without [externalOffered], only the place: a phone opens no terminal
  /// window.
  Widget _whereItWorks(
    bool worktreeOffered,
    Repository? checkout, {
    required bool externalOffered,
  }) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (externalOffered) ...[
        SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
              value: false,
              icon: Icon(AppIcons.chat, size: Chrome.iconAction),
              label: Text('In-app'),
            ),
            ButtonSegment(
              value: true,
              icon: Icon(AppIcons.arrowSquareOut, size: Chrome.iconAction),
              label: Text('External terminal'),
            ),
          ],
          selected: {_external},
          onSelectionChanged: (s) => setState(() => _external = s.first),
        ),
        if (_external) _terminalPicker(),
      ],
      if (!_external) _keepHereChoice(),
      if (worktreeOffered) ...[
        if (externalOffered) const SizedBox(height: Insets.xs),
        _placeChoice(checkout),
      ],
    ],
  );

  /// The three places of board N3, each with a line saying what it means.
  Widget _placeChoice(Repository? checkout) {
    final joinable = _joinable(checkout);
    final free = _freeBranches();
    final choices = _existingChoices(checkout);
    final own = _ownBranch(checkout);
    final listed = _worktrees != null && _branchesRead;
    final touch = UiDensity.of(context).isTouch;
    return RadioGroup<_WorkPlace>(
      groupValue: _place,
      onChanged: (v) {
        if (_busy || v == null) return;
        setState(() {
          _place = v;
          _existingPick ??= choices.firstOrNull?.value;
        });
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RadioListTile<_WorkPlace>(
            key: const ValueKey('new-session-place:checkout'),
            value: _WorkPlace.checkout,
            dense: !touch,
            contentPadding: EdgeInsets.zero,
            title: const Text('The project checkout'),
            subtitle: Text(
              own == null
                  ? 'Works in ${checkout?.path.path ?? 'the checkout'}.'
                  : 'Works on $own in ${checkout?.path.path}.',
            ),
          ),
          RadioListTile<_WorkPlace>(
            key: const ValueKey('new-session-place:worktree'),
            value: _WorkPlace.newWorktree,
            dense: !touch,
            contentPadding: EdgeInsets.zero,
            title: const Text('A new worktree'),
            subtitle: const Text(
              'Its own folder and branch, so it cannot trip over other '
              'sessions. Merge back when done.',
            ),
          ),
          if (_place == _WorkPlace.newWorktree) _newWorktreeFields(checkout),
          RadioListTile<_WorkPlace>(
            key: const ValueKey('new-session-place:existing'),
            value: _WorkPlace.existing,
            dense: !touch,
            contentPadding: EdgeInsets.zero,
            enabled: choices.isNotEmpty,
            title: const Text('An existing branch or worktree'),
            subtitle: Text(
              choices.isNotEmpty
                  ? _existingSummary(joinable.length, free.length)
                  : !listed
                  ? 'Looking for branches and worktrees…'
                  : 'Every branch is checked out, and this checkout has no '
                        'other worktree.',
            ),
          ),
          if (_place == _WorkPlace.existing && choices.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: Insets.xl),
              child: FilterMenuField<String?>(
                key: ValueKey(
                  'new-session-existing-worktree:${checkout?.path.path}',
                ),
                label: 'Branch or worktree',
                entries: choices,
                selected: _existingPick,
                enabled: !_busy,
                filterHint: 'Filter branches and worktrees',
                emptyLabel: 'Choose one',
                onSelected: (v) => setState(() => _existingPick = v),
              ),
            ),
        ],
      ),
    );
  }

  /// How many of each kind the existing choice holds, in a sentence.
  static String _existingSummary(int worktrees, int branches) {
    final join = 'join one of $worktrees worktree${worktrees == 1 ? '' : 's'}';
    final branch =
        'check out one of $branches branch${branches == 1 ? '' : 'es'} in a '
        'new worktree';
    final said = worktrees > 0 && branches > 0
        ? '$join, or $branch'
        : worktrees > 0
        ? join
        : branch;
    return '${said[0].toUpperCase()}${said.substring(1)}.';
  }

  /// The new worktree's branch and what it starts from. Rows of Expanded, not
  /// a LayoutBuilder: the dialog measures intrinsics.
  Widget _newWorktreeFields(Repository? checkout) {
    final bases = _baseChoices(checkout);
    return Padding(
      padding: const EdgeInsets.only(left: Insets.xl, bottom: Insets.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('new-session-worktree-branch'),
              controller: _branchController,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'Branch',
                helperText: 'Blank names it after the session.',
              ),
            ),
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: FilterMenuField<String?>(
              key: ValueKey('new-session-worktree-base:${checkout?.path.path}'),
              label: 'From',
              entries: bases,
              // A base no longer listed reads as HEAD, which is what is sent.
              selected: _baseListed() ? _base : null,
              enabled: !_busy,
              filterHint: 'Filter branches',
              onSelected: (v) => setState(() => _base = v),
            ),
          ),
        ],
      ),
    );
  }
}
