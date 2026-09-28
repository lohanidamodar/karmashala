import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/primitives.dart';

import '../../agents/application/agent_installations_controller.dart';
import 'package:agent_cli/discovery.dart';
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
import 'new_dialog_section.dart';
import 'new_session_agent_cards.dart';

/// Creates a session **where you say**. Browsing and cancelling leaves the
/// app's selection alone; pressing Start moves it, it being no longer a guess.
class NewSessionDialog extends ConsumerStatefulWidget {
  const NewSessionDialog({this.targetPaneId, super.key});

  /// Opens the session flow, optionally placing an in-app session in an empty
  /// split instead of creating another workbench tab.
  static Future<void> show(BuildContext context, {String? targetPaneId}) =>
      showDialog<void>(
        context: context,
        builder: (_) => NewSessionDialog(targetPaneId: targetPaneId),
      );

  final String? targetPaneId;

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
  bool _useWorktree = false;
  bool _external = false;
  SystemTerminal? _terminal;
  bool _busy = false;
  String? _error;

  /// The worktree this launch is creating; kept after it ends, so a failed
  /// stage's output stays on screen beside the error.
  WorktreeCreationTracker? _creation;

  @override
  void initState() {
    super.initState();
    // Taken once, never overwriting the picker's own choice — but still
    // listened to, so a project added from the empty state below is picked up.
    _destination = ref.read(defaultSessionDestinationProvider);
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
    });
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
    _titleController.dispose();
    _promptController.dispose();
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

  /// [useWorktree] comes from the button, not the field: a checkbox that is
  /// not on screen must not still be ticked underneath it.
  Future<void> _create(
    AgentInstallation? installation, {
    required bool useWorktree,
  }) async {
    final repo = _destination?.checkout;
    if (repo == null || installation == null) return;
    final terminal = _terminalFrom(
      ref.read(availableSystemTerminalsProvider).asData?.value ?? const [],
    );

    setState(() {
      _busy = true;
      _error = null;
      _creation = null;
    });
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
      if (mounted) setState(() => _busy = false);
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

  /// In the app or in a terminal of its own, and in the checkout or a fresh
  /// worktree beside it. The worktree is offered for both surfaces: it is
  /// created before the agent starts, so its window makes no difference.
  Widget _whereItWorks(bool worktreeOffered) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
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
      if (worktreeOffered) ...[
        const SizedBox(height: Insets.xs),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          value: _useWorktree,
          onChanged: (v) => setState(() => _useWorktree = v ?? false),
          title: const Text('Run in a dedicated Git worktree'),
        ),
      ],
    ],
  );

  /// The workspace has nothing to run a session in, and says so instead of
  /// offering an empty dropdown.
  Widget _noProjects() => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'There are no projects yet, so there is nowhere to start a session. '
        'Add a project first — a folder with your Git checkouts in it.',
      ),
      const SizedBox(height: Insets.md),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.tonalIcon(
          onPressed: () => NewProjectDialog.show(context),
          icon: const Icon(AppIcons.folderPlus, size: Chrome.iconAction),
          label: const Text('Add project…'),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final destination = _destination;
    final checkout = destination?.checkout;

    // Only the agents installed **where the session will run**: one discovered
    // on Windows is a Windows path, unresolvable inside a WSL checkout.
    final installations = checkout == null
        ? const <AgentInstallation>[]
        : [
            for (final i in ref.watch(agentInstallationsControllerProvider))
              if (i.environmentId == checkout.path.environmentId) i,
          ];
    final installation = _agentFor(checkout, installations);

    // A worktree is git's, so it is offered only where there is a repository to
    // take one from. Only a positive [GitPresence.notARepository] withdraws it.
    final worktreeOffered =
        checkout != null && _presence != GitPresence.notARepository;

    final canStart = !_busy && checkout != null && installation != null;
    void start() =>
        _create(installation, useWorktree: worktreeOffered && _useWorktree);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () {
          if (canStart) start();
        },
      },
      child: AlertDialog(
        title: const DesktopDialogTitle(
          icon: AppIcons.chatCircleDots,
          title: 'New session',
          subtitle: 'Choose where and how the coding agent should run.',
        ),
        // The whole dialog scrolls, title included: with only the body scrolling,
        // Tab left the title field above the window at 1.3x text.
        scrollable: true,
        // One width whatever the agent cards hold, so the dialog does not
        // resize as they load; it still gives way to a narrower window.
        // AlertDialog sizes its body by intrinsics, so nothing in it may be
        // a LayoutBuilder.
        content: SizedBox(
          width: DialogWidth.narrow,
          child: Column(
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
              destination == null
                  ? _noProjects()
                  : Column(
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
                                  onSelected: (v) =>
                                      setState(() => _installation = v),
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
                        NewDialogSection(
                          label: 'Where it works',
                          child: _whereItWorks(worktreeOffered),
                        ),
                        NewDialogSection(
                          label: 'First prompt',
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              TextField(
                                controller: _titleController,
                                decoration: const InputDecoration(
                                  labelText: 'Title',
                                ),
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
                      ],
                    ),
            ],
          ),
        ),
        actions: [
          TextButton(
            // While a worktree is being made, Cancel stops that — and cleans up —
            // rather than closing a dialog whose launch would carry on unseen.
            onPressed: !_busy
                ? () => Navigator.of(context).pop()
                : (_creation?.canCancel ?? false)
                ? () {
                    _creation!.cancel();
                    setState(() {});
                  }
                : null,
            child: const Text('Cancel'),
          ),
          Tooltip(
            message: 'Start the session (Ctrl+Enter)',
            child: FilledButton(
              onPressed: canStart ? start : null,
              child: _busy
                  ? const InlineSpinner(size: InlineSpinnerSize.medium)
                  : const LabelWithChord(label: 'Start', chord: 'Ctrl+Enter'),
            ),
          ),
        ],
      ),
    );
  }
}
