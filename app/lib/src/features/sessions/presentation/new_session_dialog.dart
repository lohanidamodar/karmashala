import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/primitives.dart';

import '../../../app/widgets/full_screen_form.dart';
import '../../../core/capabilities/capabilities.dart';
import '../../agents/application/agent_installations_controller.dart';
import 'package:agent_cli/discovery.dart';
import '../../environments/application/environment_values.dart'
    show EnvironmentPath;
import '../../environments/application/environments_controller.dart';
import 'package:karmashala_git/git.dart';
import '../../explorer/application/explorer_actions.dart';
import '../../git/application/changes_providers.dart';
import '../../git/application/git_providers.dart';
import 'package:karmashala_git/worktrees.dart';
import '../../git/presentation/worktree_creation_view.dart';
import '../../projects/application/projects_controller.dart';
import '../../projects/presentation/new_project_dialog.dart';
import '../../terminal/application/system_terminal_providers.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import '../application/session_defaults.dart';
import '../application/session_launcher.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_session/launch.dart';
import 'session_destination_picker.dart';
import 'slow_start_note.dart';
import 'filter_menu_field.dart';
import 'new_dialog_section.dart';
import 'new_session_agent_cards.dart';

/// Where a new session's work lands (spec §5, board N3). [existing] is an
/// existing branch — checked out in a new worktree — or an existing worktree,
/// joined.
enum _WorkPlace { checkout, newWorktree, existing }

/// The prefixes of an existing-place pick: one choice list holds both kinds.
const _pickWorktree = 'worktree:';
const _pickBranch = 'branch:';

/// Whether [name] could be a branch: the refusals of
/// `git check-ref-format --branch` a person is likely to type, caught before
/// the server is asked.
bool _isBranchName(String name) =>
    !name.startsWith('-') &&
    !name.startsWith('/') &&
    !name.endsWith('/') &&
    !name.endsWith('.') &&
    !name.endsWith('.lock') &&
    !name.contains('..') &&
    !name.contains('//') &&
    !name.contains('@{') &&
    !RegExp(r'[\s~^:?*\[\\\x00-\x1f\x7f]').hasMatch(name);

/// Creates a session **where you say**. Browsing and cancelling leaves the
/// app's selection alone; pressing Start moves it, it being no longer a guess.
class NewSessionDialog extends ConsumerStatefulWidget {
  const NewSessionDialog({
    this.targetPaneId,
    this.destination,
    this.firstPrompt,
    this.title,
    super.key,
  });

  /// Opens the session flow, optionally placing an in-app session in an empty
  /// split instead of creating another workbench tab.
  /// A phone not granted `start_session` is told so instead: every way in
  /// comes through here.
  static Future<void> show(
    BuildContext context, {
    String? targetPaneId,
    SessionDestination? destination,
    String? firstPrompt,
    String? title,
  }) {
    final container = ProviderScope.containerOf(context, listen: false);
    if (!container.read(capabilitiesProvider).mayStart) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text(kStartNotGranted)));
      return Future.value();
    }
    return showFormDialog<void>(
      context: context,
      builder: (_) => NewSessionDialog(
        targetPaneId: targetPaneId,
        destination: destination,
        firstPrompt: firstPrompt,
        title: title,
      ),
    );
  }

  final String? targetPaneId;

  /// Filled into the first prompt for the person to read, edit and start:
  /// a review, a crash or a failed run handed over is never sent unseen.
  final String? firstPrompt;

  /// The session title the dialog opens with, in place of the default.
  final String? title;

  /// Where the dialog opens pointed, when the caller already named a project
  /// or a checkout — quick open's project step. Null is whatever the app is
  /// pointed at ([defaultSessionDestinationProvider]). Either way the
  /// selection is left alone until Start.
  final SessionDestination? destination;

  @override
  ConsumerState<NewSessionDialog> createState() => _NewSessionDialogState();
}

class _NewSessionDialogState extends ConsumerState<NewSessionDialog> {
  final _titleController = TextEditingController(text: defaultSessionTitle);

  /// What the agent is told first, if anything: the session starts with it
  /// rather than at an empty prompt.
  final _promptController = TextEditingController();
  AgentInstallation? _installation;

  /// Null only while the workspace has no projects at all.
  SessionDestination? _destination;

  /// Whether [_destination]'s checkout is under git, as far as the filesystem
  /// could say. Starts — and stays, for an SSH checkout — at
  /// [GitPresence.unknown], which offers a worktree: not having looked is not
  /// the same as having found a plain folder.
  GitPresence _presence = GitPresence.unknown;
  _WorkPlace _place = _WorkPlace.checkout;

  /// The new worktree's branch; blank lets the server name it after the session.
  final _branchController = TextEditingController();

  /// What the new branch starts from; null is the checkout's HEAD.
  String? _base;

  /// The destination's worktrees, read once per destination; null until read.
  List<GitWorktree>? _worktrees;

  /// The destination's branches, local and remote-tracking, read once per
  /// destination; null until read, or when the server could not list them —
  /// then the bases fall back to the branches the worktrees name.
  List<GitBranchRef>? _branches;
  bool _branchesRead = false;

  /// The existing branch or worktree picked: [_pickBranch] or [_pickWorktree]
  /// and its name or path.
  String? _existingPick;
  bool _external = false;
  SystemTerminal? _terminal;
  bool _busy = false;
  String? _error;

  /// Set once a start has been busy for a while: an agent run through npx
  /// is downloaded on its first start, and a silent spinner looked hung.
  bool _slowStart = false;
  Timer? _slowStartTimer;

  /// The worktree this launch is creating; kept after it ends, so a failed
  /// stage's output stays on screen beside the error.
  WorktreeCreationTracker? _creation;

  @override
  void initState() {
    super.initState();
    if (widget.firstPrompt case final prompt?) _promptController.text = prompt;
    if (widget.title case final title?) _titleController.text = title;
    // Taken once, never overwriting the picker's own choice — but still
    // listened to, so a project added from the empty state below is picked up.
    _destination =
        widget.destination ?? ref.read(defaultSessionDestinationProvider);
    _afterDestinationChanged();
    ref.listenManual(defaultSessionDestinationProvider, (_, next) {
      if (_destination == null && next != null) {
        setState(() => _destination = next);
        _afterDestinationChanged();
      }
    });
  }

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

  @override
  void dispose() {
    _slowStartTimer?.cancel();
    _titleController.dispose();
    _promptController.dispose();
    _branchController.dispose();
    super.dispose();
  }

  /// The agent the dialog will start: the one picked, while it is still
  /// installed where the session runs, else that checkout's default.
  AgentInstallation? _agentFor(
    Repository? checkout,
    List<AgentInstallation> installations,
  ) {
    if (checkout == null || installations.isEmpty) return null;
    final picked = _installation;
    if (picked != null && installations.contains(picked)) return picked;
    // The one definition of "which agent, here" — shared with the `+` button
    // in the Explorer, which runs it without asking.
    return ref
            .read(sessionDefaultsProvider)
            .forCheckout(checkout)
            .installation ??
        installations.first;
  }

  /// The agent for a session without a project: the one picked, else the
  /// first installed anywhere — its machine is where the folder goes.
  AgentInstallation? _agentForScratch(List<AgentInstallation> installations) {
    final picked = _installation;
    if (picked != null && installations.contains(picked)) return picked;
    return installations.firstOrNull;
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
              firstMessage: _promptController.text.trim().isEmpty
                  ? null
                  : _promptController.text.trim(),
            ),
            externalTerminal: terminal,
          );
      // Now — and only now — the app follows, by the rule the Explorer uses
      // when a row is clicked. Only when the project differs: selecting scans.
      if (ref.read(selectedProjectIdProvider) != repo.projectId) {
        ref.read(selectedProjectIdProvider.notifier).select(repo.projectId);
      }
      ref.read(explorerActionsProvider).selectNative(launched.session);
      if (mounted) Navigator.of(context).pop();
    } on WorktreeCreationCancelled catch (e) {
      if (mounted) setState(() => _error = 'Cancelled. ${e.cleanup}');
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not start session: $e');
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

  @override
  Widget build(BuildContext context) {
    // Never null since a workspace with no projects opens on "No project";
    // kept nullable for the moment before the first frame reads the default.
    final destination = _destination ?? const SessionDestination.scratch();
    final checkout = destination.checkout;
    final scratch = destination.isScratch;

    // Only the agents installed **where the session will run**: one discovered
    // on Windows is a Windows path, unresolvable inside a WSL checkout. A
    // session without a project runs wherever its agent is, so every agent.
    final installations = scratch
        ? ref.watch(agentInstallationsControllerProvider)
        : checkout == null
        ? const <AgentInstallation>[]
        : [
            for (final i in ref.watch(agentInstallationsControllerProvider))
              if (i.environmentId == checkout.path.environmentId) i,
          ];
    final installation = scratch
        ? _agentForScratch(installations)
        : _agentFor(checkout, installations);

    // A worktree is git's, so it is offered only where there is a repository to
    // take one from. Only a positive [GitPresence.notARepository] withdraws it.
    final worktreeOffered =
        checkout != null && _presence != GitPresence.notARepository;
    final externalOffered = ref.watch(
      capabilitiesProvider.select((c) => c.externalTerminalSessions),
    );

    final canStart =
        !_busy && (checkout != null || scratch) && installation != null;
    void start() => _create(
      installation,
      place: worktreeOffered ? _place : _WorkPlace.checkout,
    );
    // While a worktree is being made, Cancel stops that — and cleans up —
    // rather than closing a dialog whose launch would carry on unseen.
    final VoidCallback? cancel = !_busy
        ? () => Navigator.of(context).pop()
        : (_creation?.canCancel ?? false)
        ? () {
            _creation!.cancel();
            setState(() {});
          }
        : null;
    final fullScreen = opensFullScreen(context);
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // One dialog, two tabs (spec §5): Project swaps this dialog for
        // the new-project one in the same place. In the body, not the
        // title, so it scrolls into view with the rest.
        NewKindSwitch(
          current: NewKind.session,
          onChanged: (_) {
            final navigator = Navigator.of(context);
            final host = navigator.context;
            navigator.pop();
            NewProjectDialog.show(host);
          },
        ),
        // Four labelled parts in the order the choice is made (spec
        // §5): who runs, on what, where the work lands, what it is told.
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            NewDialogSection(
              label: 'Agent',
              first: true,
              child: installations.isEmpty
                  ? _noAgents(checkout)
                  : NewSessionAgentCards(
                      installations: installations,
                      selected: installation,
                      enabled: !_busy,
                      onSelected: (v) => setState(() => _installation = v),
                    ),
            ),
            NewDialogSection(
              label: 'Project & machine',
              child: SessionDestinationPicker(
                destination: destination,
                enabled: !_busy,
                onChanged: (picked) {
                  setState(() {
                    _error = null;
                    _destination = picked;
                    // The agent belongs to the environment we are
                    // leaving. Cleared so `_agentFor` re-resolves
                    // the default.
                    _installation = null;
                  });
                  _afterDestinationChanged();
                },
              ),
            ),
            if (externalOffered || worktreeOffered)
              NewDialogSection(
                label: 'Where it works',
                child: _whereItWorks(
                  worktreeOffered,
                  checkout,
                  externalOffered: externalOffered,
                ),
              ),
            NewDialogSection(
              label: 'First prompt',
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _titleController,
                    decoration: const InputDecoration(labelText: 'Title'),
                  ),
                  const SizedBox(height: Insets.md),
                  TextField(
                    controller: _promptController,
                    minLines: 2,
                    maxLines: 6,
                    decoration: const InputDecoration(
                      labelText: 'First message (optional)',
                      hintText: 'What should the agent start on?',
                    ),
                  ),
                ],
              ),
            ),
            if (_creation != null) ...[
              const SizedBox(height: Insets.md),
              WorktreeCreationLiveView(tracker: _creation!),
            ],
            if (_error != null) ...[
              const SizedBox(height: Insets.md),
              DesktopErrorBanner(_error!),
            ],
            if (_busy && _slowStart) ...[
              const SizedBox(height: Insets.md),
              const SlowStartNote(),
            ],
          ],
        ),
      ],
    );
    if (fullScreen) {
      return FullScreenForm(
        title: 'New session',
        body: body,
        onClose: cancel,
        primary: FilledButton(
          onPressed: canStart ? start : null,
          child: _busy
              ? const InlineSpinner(size: InlineSpinnerSize.medium)
              : const Text('Start'),
        ),
      );
    }
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () {
          if (canStart) start();
        },
      },
      // Tab walks the title, then the body, then the actions — three groups
      // in that order, each in reading order inside. One reading order over
      // the whole dialog measured the body as it scrolled under the pinned
      // actions: at the minimum window Tab put the last fields after Start
      // and circled the bottom four stops without returning to the top.
      child: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: AlertDialog(
          title: FocusTraversalOrder(
            order: const NumericFocusOrder(0),
            child: FocusTraversalGroup(
              child: const DesktopDialogTitle(
                icon: AppIcons.chatCircleDots,
                title: 'New session',
                subtitle: 'Choose where and how the coding agent should run.',
              ),
            ),
          ),
          // The whole dialog scrolls, title included: with only the body scrolling,
          // Tab left the title field above the window at 1.3x text.
          scrollable: true,
          // One width whatever the agent cards hold, so the dialog does not
          // resize as they load; it still gives way to a narrower window.
          // AlertDialog sizes its body by intrinsics, so nothing in it may be
          // a LayoutBuilder.
          content: FocusTraversalOrder(
            order: const NumericFocusOrder(1),
            child: FocusTraversalGroup(
              child: SizedBox(width: DialogWidth.narrow, child: body),
            ),
          ),
          actions: [
            FocusTraversalOrder(
              order: const NumericFocusOrder(2),
              child: TextButton(onPressed: cancel, child: const Text('Cancel')),
            ),
            FocusTraversalOrder(
              order: const NumericFocusOrder(3),
              child: Tooltip(
                message: 'Start the session (Ctrl+Enter)',
                child: FilledButton(
                  onPressed: canStart ? start : null,
                  child: _busy
                      ? const InlineSpinner(size: InlineSpinnerSize.medium)
                      : const LabelWithChord(
                          label: 'Start',
                          chord: 'Ctrl+Enter',
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
