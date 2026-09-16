import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/primitives.dart';

import '../../agents/application/agent_installations_controller.dart';
import 'package:agent_cli/discovery.dart';
import '../../environments/application/environments_controller.dart';
import '../../explorer/application/explorer_actions.dart';
import '../../projects/application/projects_controller.dart';
import '../../projects/presentation/new_project_dialog.dart';
import '../../terminal/application/system_terminal_providers.dart';
import '../../terminal/data/system_terminal_service.dart';
import '../application/session_defaults.dart';
import '../application/session_launcher.dart';
import 'package:karmashala_session/launch.dart';
import 'session_destination_picker.dart';

/// Creates a session **where you say**. Browsing and cancelling leaves the
/// app's selection alone; pressing Start moves it, it being no longer a guess.
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
      // One call for both branches: in-app and external are the same creation
      // path with a different surface, so every field means the same thing.
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
              targetPaneId: widget.targetPaneId,
            ),
            externalTerminal: _terminal,
          );
      // Now — and only now — the app follows, by the rule the Explorer uses
      // when a row is clicked. Only when the project differs: selecting scans.
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
        _terminal ??= list.first;
        return Padding(
          padding: const EdgeInsets.only(top: Insets.md),
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
    // watched, so a project added from the empty state below is picked up.
    _destination ??= ref.watch(defaultSessionDestinationProvider);
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
      title: const DesktopDialogTitle(
        icon: AppIcons.chatCircleDots,
        title: 'New session',
        subtitle: 'Choose where and how the coding agent should run.',
      ),
      // The whole dialog scrolls, title included: with only the body scrolling,
      // Tab left the title field above the window at 1.3x text.
      scrollable: true,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: DialogWidth.narrow),
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
                      // Cleared so the block above re-resolves the default.
                      _installation = null;
                    }),
                  ),
                  const SizedBox(height: Insets.md),
                  TextField(
                    controller: _titleController,
                    decoration: const InputDecoration(labelText: 'Title'),
                  ),
                  const SizedBox(height: Insets.md),
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
                      // Keyed by environment for the reason the checkout list
                      // is keyed by project: a stale `FormField` value asserts.
                      key: ValueKey(
                        'agent-in-${checkout?.path.environmentId ?? ''}',
                      ),
                      initialValue: _installation,
                      // Expanded and ellipsised: the label carries an id, an
                      // environment and a version, wider than the field at 200%.
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Agent'),
                      items: [
                        for (final i in installations)
                          DropdownMenuItem(
                            value: i,
                            child: Text(
                              '${i.agentId} · '
                              // Not the raw id: it is the literal `windows` on
                              // every platform, so a Mac was offered `windows`.
                              '${ref.watch(environmentLabelForIdProvider(i.environmentId))}'
                              '${i.version == null ? '' : ' (${i.version})'}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) => setState(() => _installation = v),
                    ),
                  const SizedBox(height: Insets.md),
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
                  // Offered for both surfaces: the worktree is created before
                  // the agent starts, so its window makes no difference.
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _useWorktree,
                    onChanged: (v) => setState(() => _useWorktree = v ?? false),
                    title: const Text('Run in a dedicated Git worktree'),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: Insets.sm),
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
              ? const InlineSpinner(size: InlineSpinnerSize.medium)
              : const Text('Start'),
        ),
      ],
    );
  }
}
