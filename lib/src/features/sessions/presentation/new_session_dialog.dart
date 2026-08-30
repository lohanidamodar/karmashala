import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/widgets/desktop_dialog.dart';

import '../../agents/application/agent_installations_controller.dart';
import '../../agents/domain/agent_installation.dart';
import '../../git/application/changes_providers.dart';
import '../../repositories/application/repository_providers.dart';
import '../../settings/application/settings_controller.dart';
import '../../terminal/application/system_terminal_providers.dart';
import '../../terminal/data/system_terminal_service.dart';
import '../application/session_launcher.dart';
import '../application/session_ui_providers.dart';
import '../domain/session_launch.dart';

/// Creates a session for the selected repository: pick an agent installation, a
/// title, and whether to run in a dedicated Git worktree.
class NewSessionDialog extends ConsumerStatefulWidget {
  const NewSessionDialog({super.key});

  static Future<void> show(BuildContext context) => showDialog<void>(
    context: context,
    builder: (_) => const NewSessionDialog(),
  );

  @override
  ConsumerState<NewSessionDialog> createState() => _NewSessionDialogState();
}

class _NewSessionDialogState extends ConsumerState<NewSessionDialog> {
  final _titleController = TextEditingController(text: 'New session');
  AgentInstallation? _installation;
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
    final repoId = ref.read(selectedRepositoryIdProvider);
    final installation = _installation;
    if (repoId == null || installation == null) return;
    final repo = ref.read(repositoryDaoProvider).getById(repoId);
    if (repo == null) return;

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
            ),
          );
      ref.read(selectedSessionIdProvider.notifier).select(launched.session.id);
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

  @override
  Widget build(BuildContext context) {
    final installations = ref.watch(agentInstallationsControllerProvider);
    if (_installation == null && installations.isNotEmpty) {
      // Prefer the configured default installation, else the default kind,
      // else the first installation.
      final settings = ref.read(settingsControllerProvider);
      _installation =
          resolveDefaultInstallation(
            installations,
            defaultInstallationId: settings.defaultAgentInstallationId,
            defaultAgentId: settings.defaultAgent,
          ) ??
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            const SizedBox(height: 12),
            if (installations.isEmpty)
              Row(
                children: [
                  const Expanded(
                    child: Text('No agent installations found yet.'),
                  ),
                  TextButton(
                    onPressed: _busy ? null : _discoverAgents,
                    child: const Text('Discover agents'),
                  ),
                ],
              )
            else
              DropdownButtonFormField<AgentInstallation>(
                initialValue: _installation,
                // Expanded and ellipsised: the label carries an id, an
                // environment and a version, which is wider than the field once
                // the user scales text up.
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Agent'),
                items: [
                  for (final i in installations)
                    DropdownMenuItem(
                      value: i,
                      child: Text(
                        '${i.agentId} · ${i.environmentId}'
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
                  icon: Icon(AppIcons.chat, size: 15),
                  label: Text('In-app'),
                ),
                ButtonSegment(
                  value: true,
                  icon: Icon(AppIcons.arrowSquareOut, size: 15),
                  label: Text('External terminal'),
                ),
              ],
              selected: {_external},
              onSelectionChanged: (s) => setState(() => _external = s.first),
            ),
            if (_external) _terminalPicker(),
            // Offered for both surfaces now: the worktree is created before the
            // agent starts, so where the agent's window happens to be makes no
            // difference to it. It used to be reachable from one path of nine.
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
          onPressed: (_busy || _installation == null) ? null : _create,
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
