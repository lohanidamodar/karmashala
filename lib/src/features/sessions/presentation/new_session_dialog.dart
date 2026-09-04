import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_dialog.dart';

import '../../agents/application/agent_installations_controller.dart';
import '../../agents/domain/agent_installation.dart';
import '../../environments/application/environments_controller.dart';
import '../../explorer/application/explorer_actions.dart';
import '../../projects/application/projects_controller.dart';
import '../../projects/presentation/new_project_dialog.dart';
import '../../terminal/application/system_terminal_providers.dart';
import '../../terminal/data/system_terminal_service.dart';
import '../application/session_defaults.dart';
import '../application/session_launcher.dart';
import '../domain/session_launch.dart';
import 'session_destination_picker.dart';

/// Creates a session **where you say**: pick a project and a checkout inside
/// it, an agent, a title, and whether to run in a dedicated Git worktree.
///
/// It used to create a session for whatever the app happened to be pointed at,
/// which meant starting one somewhere else cost a trip to the Explorer to move
/// the selection first — and left it moved afterwards.
/// [SessionDestinationPicker] is that trip, folded into the dialog.
///
/// **Choosing a destination here does not move the app's selection.** Opening
/// this dialog, browsing the projects in it and pressing Cancel leaves
/// everything exactly as it was: saying *"start one over there"* is not the
/// same as saying *"I work over there now"*, and relocating the Explorer under
/// a user who was only looking would be a worse bug than the friction being
/// fixed. **Pressing Start does move it**, because by then it is no longer a
/// guess: the app follows the session it just created to where it runs, exactly
/// as clicking that session's row would — otherwise the pane in front of you
/// and the Changes, GitHub and Repository panels beside it would be describing
/// two different checkouts.
class NewSessionDialog extends ConsumerStatefulWidget {
  const NewSessionDialog({this.targetPaneId, super.key});

  /// Opens the session flow, optionally placing an in-app session in an empty
  /// split instead of creating another workbench tab.
  static Future<void> show(
    BuildContext context, {
    String? targetPaneId,
  }) => showDialog<void>(
    context: context,
    builder: (_) => NewSessionDialog(targetPaneId: targetPaneId),
  );

  final String? targetPaneId;

  @override
  ConsumerState<NewSessionDialog> createState() => _NewSessionDialogState();
}

class _NewSessionDialogState extends ConsumerState<NewSessionDialog> {
  final _titleController = TextEditingController(text: defaultSessionTitle);
  AgentInstallation? _installation;

  /// Null until the first build resolves it, and null *after* that only when
  /// the workspace has no projects at all.
  SessionDestination? _destination;
  bool _useWorktree = false;
  bool _external = false;
  SystemTerminal? _terminal;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

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

  Future<void> _create() async {
    final repo = _destination?.checkout;
    final installation = _installation;
    if (repo == null || installation == null) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_external && _terminal == null) {
        setState(() => _error = 'Choose a terminal to launch in.');
        return;
      }
      // One call for both branches. In-app and external are now the same
      // creation path with a different surface, so the title, the worktree
      // choice and the permission mode mean the same thing in both — the title
      // field used to be drawn over the external branch and quietly discarded.
      final launched = await ref
          .read(sessionLauncherProvider)
          .launch(
            SessionLaunchRequest(
              repository: repo,
              installation: installation,
              title: _titleController.text,
              purpose: SessionPurpose.newSession,
              surface: _external
                  ? SessionSurface.external
                  : SessionSurface.pane,
              useWorktree: _useWorktree,
              externalTerminal: _terminal,
              targetPaneId: widget.targetPaneId,
            ),
          );
      // Now — and only now — the app follows. `selectNative` is the same rule
      // the Explorer uses when a session row is clicked; the project is set
      // beside it, and only when it differs, because selecting one starts a
      // CLI-store scan.
      if (ref.read(selectedProjectIdProvider) != repo.projectId) {
        ref.read(selectedProjectIdProvider.notifier).select(repo.projectId);
      }
      ref.read(explorerActionsProvider).selectNative(launched.session);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = 'Could not start session: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _terminalPicker() {
    final terminals = ref.watch(availableSystemTerminalsProvider);
    return terminals.when(
      loading: () => const Padding(
        padding: EdgeInsets.only(top: 12),
        child: LinearProgressIndicator(),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text('Could not detect terminals: $e'),
      ),
      data: (list) {
        if (list.isEmpty) {
          return const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text('No external terminals were found on PATH.'),
          );
        }
        _terminal ??= list.first;
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: DropdownButtonFormField<SystemTerminal>(
            initialValue: list.contains(_terminal) ? _terminal : list.first,
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
    // `??=`, so the picker's own choice is never overwritten — but still
    // watched, so a project added from the empty state below (or a selection
    // that moves behind the dialog before anything is chosen) is picked up.
    _destination ??= ref.watch(defaultSessionDestinationProvider);
    final destination = _destination;
    final checkout = destination?.checkout;

    // Only the agents installed **where the session will run**. An agent
    // discovered on Windows is a Windows executable path, and launching it
    // against a WSL checkout would put a path the distribution cannot resolve
    // on its command line. This is the same list the Explorer's "…with" menu
    // offers for a row.
    final installations = checkout == null
        ? const <AgentInstallation>[]
        : [
            for (final i in ref.watch(agentInstallationsControllerProvider))
              if (i.environmentId == checkout.path.environmentId) i,
          ];
    if (checkout != null &&
        installations.isNotEmpty &&
        (_installation == null || !installations.contains(_installation))) {
      // The one definition of "which agent, here" — shared with the `+` button
      // in the Explorer, which runs it without asking.
      _installation =
          ref.read(sessionDefaultsProvider).forCheckout(checkout).installation ??
          installations.first;
    }

    return AlertDialog(
      scrollable: true,
      title: const DesktopDialogTitle(
        icon: AppIcons.chatCircleDots,
        title: 'New session',
        subtitle: 'Choose where and how the coding agent should run.',
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: destination == null
            ? _noProjects()
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SessionDestinationPicker(
                    destination: destination,
                    enabled: !_busy,
                    onChanged: (picked) => setState(() {
                      _destination = picked;
                      // The agent belongs to the environment we are leaving.
                      // Cleared rather than carried, so the block above
                      // re-resolves the default for where we are going.
                      _installation = null;
                    }),
                  ),
                  const SizedBox(height: Insets.md),
                  TextField(
                    controller: _titleController,
                    decoration: const InputDecoration(labelText: 'Title'),
                  ),
                  const SizedBox(height: 12),
                  if (installations.isEmpty)
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            checkout == null
                                ? 'No agent installations found yet.'
                                : 'No agent is installed in '
                                      '${ref.watch(environmentLabelForIdProvider(checkout.path.environmentId))} yet.',
                          ),
                        ),
                        TextButton(
                          onPressed: _busy ? null : _discoverAgents,
                          child: const Text('Discover agents'),
                        ),
                      ],
                    )
                  else
                    DropdownButtonFormField<AgentInstallation>(
                      // Keyed by environment for the reason the checkout
                      // dropdown is keyed by project: the items change with the
                      // destination, and a `FormField` holding the old value
                      // would assert rather than merely look wrong.
                      key: ValueKey(
                        'agent-in-${checkout?.path.environmentId ?? ''}',
                      ),
                      initialValue: _installation,
                      // Expanded and ellipsised: the label carries an id, an
                      // environment and a version, which is wider than the field
                      // once the user scales text up.
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Agent'),
                      items: [
                        for (final i in installations)
                          DropdownMenuItem(
                            value: i,
                            child: Text(
                              '${i.agentId} · '
                              // Not the raw id: it is the literal `windows` on
                              // every platform, so this dropdown offered
                              // `codex · windows` on a Mac.
                              '${ref.watch(environmentLabelForIdProvider(i.environmentId))}'
                              '${i.version == null ? '' : ' (${i.version})'}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) => setState(() => _installation = v),
                    ),
                  const SizedBox(height: 12),
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
                        icon: Icon(
                          AppIcons.arrowSquareOut,
                          size: Chrome.iconAction,
                        ),
                        label: Text('External terminal'),
                      ),
                    ],
                    selected: {_external},
                    onSelectionChanged: (s) =>
                        setState(() => _external = s.first),
                  ),
                  if (_external) _terminalPicker(),
                  // Offered for both surfaces now: the worktree is created
                  // before the agent starts, so where the agent's window
                  // happens to be makes no difference to it. It used to be
                  // reachable from one path of nine.
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _useWorktree,
                    onChanged: (v) => setState(() => _useWorktree = v ?? false),
                    title: const Text('Run in a dedicated Git worktree'),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    DesktopErrorBanner(_error!),
                  ],
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: (_busy || checkout == null || _installation == null)
              ? null
              : _create,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Start'),
        ),
      ],
    );
  }
}
