import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/design_tokens.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/domain/agent_installation.dart';
import '../../git/application/changes_providers.dart';
import '../../repositories/application/repository_providers.dart';
import '../application/fanout_service.dart';

class FanOutDialog extends ConsumerStatefulWidget {
  const FanOutDialog({super.key});

  static Future<void> show(BuildContext context) =>
      showDialog<void>(context: context, builder: (_) => const FanOutDialog());

  @override
  ConsumerState<FanOutDialog> createState() => _FanOutDialogState();
}

class _FanOutDialogState extends ConsumerState<FanOutDialog> {
  final _prompt = TextEditingController();
  final _selected = <String>{};
  List<FanOutResult>? _results;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _launch(List<AgentInstallation> installs) async {
    final repoId = ref.read(selectedRepositoryIdProvider);
    final repo = repoId == null
        ? null
        : ref.read(repositoryDaoProvider).getById(repoId);
    if (repo == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final results = await ref
          .read(fanOutServiceProvider)
          .launch(
            repository: repo,
            installations: installs
                .where((i) => _selected.contains(i.id))
                .toList(),
            prompt: _prompt.text,
          );
      if (mounted) setState(() => _results = results);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repoId = ref.watch(selectedRepositoryIdProvider);
    final repo = repoId == null
        ? null
        : ref.read(repositoryDaoProvider).getById(repoId);
    final installs = repo == null
        ? const <AgentInstallation>[]
        : ref
              .watch(agentInstallationDaoProvider)
              .getByEnvironment(repo.path.environmentId);
    return Dialog(
      insetPadding: const EdgeInsets.all(28),
      child: SizedBox(
        width: 1100,
        height: 760,
        child: Padding(
          padding: const EdgeInsets.all(Insets.lg),
          child: _results == null
              ? _setup(repo?.name, installs)
              : _comparison(_results!),
        ),
      ),
    );
  }

  Widget _setup(String? repoName, List<AgentInstallation> installs) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'Parallel worktree fan-out',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const SizedBox(height: Insets.xs),
      Text(
        repoName == null
            ? 'Select a repository first.'
            : 'Repository: $repoName',
      ),
      const SizedBox(height: Insets.md),
      TextField(
        controller: _prompt,
        minLines: 5,
        maxLines: 10,
        decoration: const InputDecoration(
          labelText: 'Prompt sent to every agent',
        ),
      ),
      const SizedBox(height: Insets.md),
      Text('Agents', style: Theme.of(context).textTheme.titleSmall),
      Expanded(
        child: ListView(
          children: [
            for (final install in installs)
              CheckboxListTile(
                value: _selected.contains(install.id),
                title: Text(install.agentId),
                subtitle: Text(install.version ?? install.executable.path),
                onChanged: _busy
                    ? null
                    : (value) => setState(() {
                        if (value ?? false) {
                          _selected.add(install.id);
                        } else {
                          _selected.remove(install.id);
                        }
                      }),
              ),
          ],
        ),
      ),
      if (_error != null)
        Text(
          _error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          const SizedBox(width: Insets.sm),
          FilledButton(
            onPressed: !_busy && repoName != null && _selected.length >= 2
                ? () => _launch(installs)
                : null,
            child: Text(
              _busy ? 'Launching…' : 'Launch ${_selected.length} agents',
            ),
          ),
        ],
      ),
    ],
  );

  Widget _comparison(List<FanOutResult> results) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              'Compare results',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          IconButton(
            tooltip: 'Close',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      const SizedBox(height: Insets.md),
      Expanded(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < results.length; i++) ...[
                if (i > 0) const VerticalDivider(width: 1),
                SizedBox(width: 400, child: _ResultColumn(result: results[i])),
              ],
            ],
          ),
        ),
      ),
    ],
  );
}

class _ResultColumn extends ConsumerStatefulWidget {
  const _ResultColumn({required this.result});
  final FanOutResult result;

  @override
  ConsumerState<_ResultColumn> createState() => _ResultColumnState();
}

class _ResultColumnState extends ConsumerState<_ResultColumn> {
  late Future<String> _diff;

  @override
  void initState() {
    super.initState();
    _diff = ref.read(fanOutServiceProvider).diff(widget.result);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              widget.result.agentId,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          IconButton(
            tooltip: 'Refresh diff',
            onPressed: () => setState(
              () => _diff = ref.read(fanOutServiceProvider).diff(widget.result),
            ),
            icon: const Icon(Icons.refresh, size: 17),
          ),
        ],
      ),
      Text(widget.result.session.worktree?.path ?? 'No worktree', maxLines: 2),
      const SizedBox(height: Insets.sm),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton(
          onPressed: () => _merge(context),
          child: const Text('Merge this winner'),
        ),
      ),
      const SizedBox(height: Insets.sm),
      Expanded(
        child: FutureBuilder<String>(
          future: _diff,
          builder: (context, snapshot) => SingleChildScrollView(
            child: SelectableText(
              snapshot.connectionState != ConnectionState.done
                  ? 'Loading diff…'
                  : snapshot.hasError
                  ? '${snapshot.error}'
                  : snapshot.data!.isEmpty
                  ? 'No changes yet. Refresh after the agent has worked.'
                  : snapshot.data!,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
        ),
      ),
    ],
  );

  Future<void> _merge(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Merge ${widget.result.agentId} result?'),
        content: const Text(
          'The worktree must be clean and its work committed. The session '
          'branch will be merged into the repository’s current branch.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Merge winner'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(fanOutServiceProvider).mergeWinner(widget.result);
      messenger.showSnackBar(const SnackBar(content: Text('Winner merged.')));
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }
}
