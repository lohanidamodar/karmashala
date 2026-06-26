import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/application/agent_installations_controller.dart';
import '../../agents/domain/agent_installation.dart';
import '../../git/application/changes_providers.dart';
import '../../repositories/application/repository_providers.dart';
import '../application/session_engine_provider.dart';
import '../application/session_ui_providers.dart';

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
      final session = await ref
          .read(sessionEngineProvider)
          .start(
            repository: repo,
            installation: installation,
            title: _titleController.text.trim().isEmpty
                ? 'Session'
                : _titleController.text.trim(),
            useWorktree: _useWorktree,
          );
      ref.read(sessionsRevisionProvider.notifier).bump();
      ref.read(selectedSessionIdProvider.notifier).select(session.id);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = 'Could not start session: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final installations = ref.watch(agentInstallationsControllerProvider);
    _installation ??= installations.isNotEmpty ? installations.first : null;

    return AlertDialog(
      title: const Text('New session'),
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
                decoration: const InputDecoration(labelText: 'Agent'),
                items: [
                  for (final i in installations)
                    DropdownMenuItem(
                      value: i,
                      child: Text(
                        '${i.agentKind.name} · ${i.environmentId}'
                        '${i.version == null ? '' : ' (${i.version})'}',
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _installation = v),
              ),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _useWorktree,
              onChanged: (v) => setState(() => _useWorktree = v ?? false),
              title: const Text('Run in a dedicated Git worktree'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
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
