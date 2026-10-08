// Choosing the agent and starting the session.

part of '../new_session_dialog.dart';

// `State.setState` is `@protected`, which covers a subclass and not an extension
// splitting that subclass's own body inside its own library.
// ignore_for_file: invalid_use_of_protected_member

extension _NewSessionStart on _NewSessionDialogState {
  /// The agent the dialog will start: the one picked, while it is still
  /// installed where the session runs, else the agent and form last started
  /// in the project, else that checkout's default.
  AgentInstallation? _agentFor(
    Repository? checkout,
    List<AgentInstallation> installations,
  ) {
    if (checkout == null || installations.isEmpty) return null;
    final picked = _installation;
    if (picked != null && installations.contains(picked)) return picked;
    if (_samePickedAgent(installations) case final same?) return same;
    final last = ref
        .read(newSessionMemoryProvider)
        .installationFor(checkout.projectId);
    if (installations.where((i) => i.id == last).firstOrNull case final i?) {
      return i;
    }
    // The one definition of "which agent, here" — shared with the `+` button
    // in the Explorer, which runs it without asking.
    return ref
            .read(sessionDefaultsProvider)
            .forCheckout(checkout)
            .installation ??
        installations.first;
  }

  /// The agent for a session without a project: the one picked, else the
  /// first installed anywhere, in the form chosen for it — its machine is
  /// where the folder goes.
  AgentInstallation? _agentForScratch(List<AgentInstallation> installations) {
    final picked = _installation;
    if (picked != null && installations.contains(picked)) return picked;
    if (_samePickedAgent(installations) case final same?) return same;
    return scratchDefaultInstallation(
      installations,
      ref.read(agentRegistryProvider),
      ref.read(settingsControllerProvider),
    );
  }

  /// The agent the person picked, as installed among [installations].
  AgentInstallation? _samePickedAgent(List<AgentInstallation> installations) {
    final agentId = _pickedAgentId;
    if (agentId == null) return null;
    return installations.where((i) => i.agentId == agentId).firstOrNull;
  }

  /// The terminal an external session opens in: the one picked, while it is
  /// still offered, else the first found.
  SystemTerminal? _terminalFrom(List<SystemTerminal> terminals) =>
      terminals.contains(_terminal) ? _terminal : terminals.firstOrNull;

  Future<void> _discoverAgents() async {
    setState(() => _busy = true);
    try {
      await ref
          .read(agentInstallationsControllerProvider.notifier)
          .discoverAll();
    } catch (e) {
      setState(() => _error = 'Agent discovery failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// [place] comes from the button, not the field: a choice that is not on
  /// screen must not still be made underneath it.
  Future<void> _create(
    AgentInstallation? installation, {
    required _WorkPlace place,
  }) async {
    final newBranch = place == _WorkPlace.newWorktree;
    final branch = _branchController.text.trim();
    if (newBranch && branch.isNotEmpty && !_isBranchName(branch)) {
      setState(() => _error = '"$branch" is not a branch name git accepts.');
      return;
    }
    // Only a pick still on offer: a branch a worktree took since the dialog
    // read the listing would otherwise be refused by git, less clearly.
    final pick = place != _WorkPlace.existing
        ? null
        : _existingChoices(
            _destination?.checkout,
          ).where((e) => e.value == _existingPick).firstOrNull?.value;
    final existing = pick == null || !pick.startsWith(_pickWorktree)
        ? null
        : _joinable(_destination?.checkout)
              .where((w) => w.path.path == pick.substring(_pickWorktree.length))
              .firstOrNull
              ?.path;
    final existingBranch = pick == null || !pick.startsWith(_pickBranch)
        ? null
        : pick.substring(_pickBranch.length);
    if (place == _WorkPlace.existing &&
        existing == null &&
        existingBranch == null) {
      setState(() => _error = 'Choose the branch or worktree to work in.');
      return;
    }
    // An existing branch is checked out in a worktree made for it.
    final useWorktree = newBranch || existingBranch != null;
    final destination = _destination;
    if (destination == null || installation == null) return;
    if (destination.checkout == null && !destination.isScratch) return;
    final terminal = _terminalFrom(
      ref.read(availableSystemTerminalsProvider).asData?.value ?? const [],
    );

    setState(() {
      _busy = true;
      _error = null;
      _loginFor = null;
      _loginNotice = null;
      _creation = null;
      _slowStart = false;
    });
    _slowStartTimer?.cancel();
    _slowStartTimer = Timer(kSlowStartAfter, () {
      if (mounted && _busy) setState(() => _slowStart = true);
    });
    // A session without a project gets its folder now, on the agent's own
    // machine, named after what it was asked to do.
    final Repository repo;
    try {
      repo =
          destination.checkout ??
          await ref
              .read(projectsControllerProvider.notifier)
              .scratchCheckout(
                installation.environmentId,
                hint: _promptController.text.trim().isEmpty
                    ? _titleController.text.trim()
                    : _promptController.text.trim(),
              );
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not make a scratch folder: $e';
          _busy = false;
          _slowStart = false;
        });
      }
      return;
    }
    // The launcher makes the worktree; this only watches for it, to draw its
    // stages and offer the cancel.
    final creations = ref.read(worktreeCreationsProvider);
    final watching = !useWorktree
        ? null
        : creations.changes.listen((_) {
            final tracker = creations.latestFor(repo.path);
            if (tracker != null && mounted && _creation != tracker) {
              setState(() => _creation = tracker);
            }
          });
    try {
      if (_external && terminal == null) {
        setState(() => _error = 'Choose a terminal to launch in.');
        return;
      }
      // An external terminal opens its own window whatever is ticked.
      final keptHere = _keepHere && !_external;
      // One call for both branches: in-app and external are the same creation
      // path with a different surface, so every field means the same thing.
      final launched = await ref
          .read(sessionLauncherProvider)
          .launch(
            SessionLaunchRequest(
              repository: repo,
              installation: installation,
              title: _titleController.text,
              titleTyped: true,
              purpose: SessionPurpose.newSession,
              surface: _external
                  ? SessionSurface.external
                  : SessionSurface.pane,
              useWorktree: useWorktree,
              worktreeBranch: newBranch && branch.isNotEmpty ? branch : null,
              worktreeBase: newBranch && _baseListed() ? _base : null,
              worktreeExistingBranch: existingBranch,
              existingWorktree: existing,
              targetPaneId: widget.targetPaneId,
              parentSessionId: _linkedParent(),
              parentLink: _linkedParent() == null ? null : SessionLink.spawn,
              firstMessage: _promptController.text.trim().isEmpty
                  ? null
                  : _promptController.text.trim(),
              openTab: !keptHere,
            ),
            externalTerminal: terminal,
          );
      ref
          .read(newSessionMemoryProvider)
          .remember(projectId: repo.projectId, installationId: installation.id);
      // Now — and only now — the app follows, by the rule the Explorer uses
      // when a row is clicked. Only when the project differs: selecting scans.
      // Kept here, nothing moves: following the row would bring its tab up.
      if (!keptHere) {
        if (ref.read(selectedProjectIdProvider) != repo.projectId) {
          ref.read(selectedProjectIdProvider.notifier).select(repo.projectId);
        }
        ref.read(explorerActionsProvider).selectNative(launched.session);
      }
      widget.onStarted?.call(launched.session, keptHere: keptHere);
      if (mounted) Navigator.of(context).pop();
    } on WorktreeCreationCancelled catch (e) {
      if (mounted) setState(() => _error = 'Cancelled. ${e.cleanup}');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (e is DataRefused && e.code == DataRefusalCode.loginRequired) {
          _error = e.message;
          _loginFor = installation;
        } else {
          _error = 'Could not start session: $e';
        }
      });
    } finally {
      await watching?.cancel();
      _slowStartTimer?.cancel();
      if (mounted) {
        setState(() {
          _busy = false;
          _slowStart = false;
        });
      }
    }
  }

  /// Opens [installation]'s login; once it is done, the refusal is stale.
  Future<void> _logIn(AgentInstallation installation) async {
    final said = await AcpLoginDialog.show(
      context,
      installationId: installation.id,
      agentName: ref
          .read(agentRegistryProvider)
          .displayNameFor(installation.agentId),
    );
    if (said != null && mounted) {
      setState(() {
        _error = null;
        _loginFor = null;
        _loginNotice = said;
      });
    }
  }
}
