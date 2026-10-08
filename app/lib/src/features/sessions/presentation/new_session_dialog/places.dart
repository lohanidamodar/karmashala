// Where the session works: presence, branches, worktrees and their choices.

part of '../new_session_dialog.dart';

// `State.setState` is `@protected`, which covers a subclass and not an extension
// splitting that subclass's own body inside its own library.
// ignore_for_file: invalid_use_of_protected_member

extension _NewSessionPlaces on _NewSessionDialogState {
  /// The two questions a destination raises that `build` may not ask: does its
  /// project have anywhere recorded to run — *recording* one writes to a
  /// provider, which a life-cycle may not do — and is that anywhere under git.
  void _afterDestinationChanged() {
    _presence = GitPresence.unknown;
    _worktrees = null;
    _branches = null;
    _branchesRead = false;
    _existingPick = null;
    _base = null;
    if (_place == _WorkPlace.existing) _place = _WorkPlace.checkout;
    Future(() async {
      if (!mounted) return;
      final runnable = await _runnable(_destination);
      if (!mounted) return;
      setState(() => _destination = runnable);
      _readPresence();
    });
  }

  /// Read once per destination rather than watched: the answer cannot change
  /// while the dialog is open, and a `build` subscribed to an autoDispose
  /// provider leaves its dispose timer behind when the dialog closes.
  void _readPresence() {
    final path = _destination?.checkout?.path;
    if (path == null) return;
    ref.read(checkoutGitPresenceProvider(path).future).then((presence) {
      if (!mounted || _destination?.checkout?.path != path) return;
      setState(() => _presence = presence);
      if (presence != GitPresence.notARepository) {
        _readWorktrees(path);
        _readBranches(path);
      }
    });
  }

  /// Every branch, for the base a new worktree starts from and the existing
  /// branch one checks out. Read, not watched, for [_readPresence]'s reason —
  /// and from the service rather than [checkoutBranchesProvider], which with
  /// no listener could be disposed while a slow WSL or SSH git still runs.
  void _readBranches(EnvironmentPath path) {
    ref
        .read(worktreeServiceProvider)
        .branches(path)
        .then(
          (listed) {
            if (!mounted || _destination?.checkout?.path != path) return;
            setState(() {
              _branches = listed;
              _branchesRead = true;
            });
          },
          onError: (Object _) {
            // A server that predates the listing, or git refusing: the bases
            // fall back to what the worktree listing names.
            if (!mounted || _destination?.checkout?.path != path) return;
            setState(() => _branchesRead = true);
          },
        );
  }

  /// The worktrees an existing-worktree launch can join, and the branches a new
  /// one can start from. Read, not watched, for [_readPresence]'s reason.
  void _readWorktrees(EnvironmentPath path) {
    ref
        .read(worktreeServiceProvider)
        .list(path)
        .then(
          (listed) {
            if (!mounted || _destination?.checkout?.path != path) return;
            setState(() => _worktrees = listed);
          },
          onError: (Object _) {
            // Unlisted reads as none: the existing-worktree choice stays shut.
            if (!mounted || _destination?.checkout?.path != path) return;
            setState(() => _worktrees = const []);
          },
        );
  }

  /// The worktrees other than the checkout itself: what "existing" can join.
  List<GitWorktree> _joinable(Repository? checkout) => [
    for (final w in _worktrees ?? const <GitWorktree>[])
      if (!w.isBare && !_isCheckout(w, checkout)) w,
  ];

  /// What a new worktree can start from: the checkout's HEAD (null), then
  /// every other branch, local before remote-tracking. Without a branch
  /// listing, the branches the worktree listing names.
  List<FilterMenuEntry<String?>> _baseChoices(Repository? checkout) {
    final own = _ownBranch(checkout);
    final head = FilterMenuEntry<String?>(
      value: null,
      label: own ?? 'Current HEAD',
      detail: 'What the checkout has out now',
      icon: AppIcons.gitBranch,
    );
    final branches = _branches;
    if (branches == null) {
      return [
        head,
        for (final name in {
          for (final w in _worktrees ?? const <GitWorktree>[])
            if (w.branch != null && w.branch != own) w.branch!,
        })
          FilterMenuEntry(value: name, label: name, icon: AppIcons.gitBranch),
      ];
    }
    return [
      head,
      for (final b in branches)
        if (!b.isRemote && !b.isCurrent && b.name != own)
          FilterMenuEntry(
            value: b.name,
            label: b.name,
            detail: b.upstream == null ? 'Local' : 'Tracks ${b.upstream}',
            icon: AppIcons.gitBranch,
          ),
      for (final b in branches)
        if (b.isRemote)
          FilterMenuEntry(
            value: b.name,
            label: b.name,
            detail: 'On ${b.remote}, fetched first',
            icon: AppIcons.globe,
          ),
    ];
  }

  /// Whether [_base] is still among the bases offered.
  bool _baseListed() =>
      _baseChoices(_destination?.checkout).any((e) => e.value == _base);

  /// Branches a new worktree can check out: a local branch no worktree has,
  /// and a remote one with no local branch of its name (checking it out makes
  /// one). A branch some worktree has is offered as that worktree instead.
  List<GitBranchRef> _freeBranches() {
    final branches = _branches ?? const <GitBranchRef>[];
    final local = {
      for (final b in branches)
        if (!b.isRemote) b.name,
    };
    return [
      for (final b in branches)
        if (b.isRemote
            ? !local.contains(b.localName)
            : b.worktree == null && !b.isCurrent)
          b,
    ];
  }

  /// The existing places, worktrees first: each joinable worktree, then each
  /// branch free to check out in a new one.
  List<FilterMenuEntry<String?>> _existingChoices(Repository? checkout) => [
    for (final w in _joinable(checkout))
      FilterMenuEntry(
        value: '$_pickWorktree${w.path.path}',
        label: w.label,
        detail: 'Join the worktree at ${w.path.path}',
        icon: AppIcons.folder,
      ),
    for (final b in _freeBranches())
      FilterMenuEntry(
        value: '$_pickBranch${b.name}',
        label: b.name,
        detail: b.isRemote
            ? 'New worktree on ${b.localName}, tracking ${b.name}'
            : 'New worktree on this branch',
        icon: b.isRemote ? AppIcons.globe : AppIcons.gitBranch,
      ),
  ];

  /// By place, not spelling: `git worktree list` writes `C:/src/x` for the
  /// checkout recorded as `C:\src\x`.
  static bool _isCheckout(GitWorktree w, Repository? checkout) =>
      checkout != null && Checkout(w.path) == Checkout(checkout.path);

  /// The branch the checkout itself has out, when the listing names it.
  String? _ownBranch(Repository? checkout) {
    for (final w in _worktrees ?? const <GitWorktree>[]) {
      if (_isCheckout(w, checkout)) return w.branch;
    }
    return null;
  }

  /// [destination] with somewhere to run: the project's own folder, recorded so
  /// every other surface sees the same row. Unchanged when there is a real
  /// reason it cannot run there, which [_error] then carries.
  Future<SessionDestination?> _runnable(SessionDestination? destination) async {
    if (destination == null || destination.isRunnable) return destination;
    try {
      return SessionDestination(
        projectId: destination.projectId,
        checkout: await ref
            .read(projectsControllerProvider.notifier)
            .ensureRunLocation(destination.projectId),
      );
    } on StateError catch (error) {
      _error = error.message;
      return destination;
    }
  }
}
