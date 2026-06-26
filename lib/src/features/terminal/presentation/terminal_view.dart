import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../environments/application/environment_providers.dart';
import '../../environments/domain/local_environment.dart';
import '../../git/application/changes_providers.dart';
import '../../repositories/application/repository_providers.dart';
import '../application/terminal_controller.dart';

/// The optional embedded terminal — a line-oriented console that runs in the
/// selected repository's environment (or the local Windows environment).
class TerminalView extends ConsumerStatefulWidget {
  const TerminalView({super.key});

  @override
  ConsumerState<TerminalView> createState() => _TerminalViewState();
}

class _TerminalViewState extends ConsumerState<TerminalView> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _start() {
    final environmentDao = ref.read(executionEnvironmentDaoProvider);
    final repoId = ref.read(selectedRepositoryIdProvider);
    final repo = repoId == null
        ? null
        : ref.read(repositoryDaoProvider).getById(repoId);
    final env =
        (repo == null
            ? environmentDao.getById(localWindowsEnvironmentId)
            : environmentDao.getById(repo.path.environmentId)) ??
        environmentDao.getById(localWindowsEnvironmentId);
    if (env == null) return;
    ref
        .read(terminalControllerProvider.notifier)
        .start(env, workingDir: repo?.path);
  }

  void _run() {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    ref.read(terminalControllerProvider.notifier).run(text);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(terminalControllerProvider);
    final notifier = ref.read(terminalControllerProvider.notifier);

    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Column(
        children: [
          Row(
            children: [
              const SizedBox(width: 12),
              Icon(Icons.terminal, size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text('Terminal', style: theme.textTheme.labelLarge),
              const Spacer(),
              if (!state.running)
                TextButton.icon(
                  onPressed: _start,
                  icon: const Icon(Icons.play_arrow, size: 16),
                  label: const Text('Start shell'),
                )
              else
                TextButton.icon(
                  onPressed: notifier.stop,
                  icon: const Icon(Icons.stop, size: 16),
                  label: const Text('Stop'),
                ),
              IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.clear_all, size: 18),
                onPressed: notifier.clear,
              ),
              IconButton(
                tooltip: 'Hide terminal',
                icon: const Icon(Icons.close, size: 18),
                onPressed: () =>
                    ref.read(terminalVisibleProvider.notifier).set(false),
              ),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: state.lines.isEmpty
                ? Center(
                    child: Text(
                      state.running
                          ? 'Shell running — type a command below.'
                          : 'Start a shell to run commands in the selected '
                                'repository.',
                      style: theme.textTheme.bodySmall,
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(8),
                    itemCount: state.lines.length,
                    itemBuilder: (context, index) {
                      final line = state.lines[index];
                      return Text(
                        line.text,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: line.isError ? theme.colorScheme.error : null,
                        ),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              controller: _input,
              enabled: state.running,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: InputDecoration(
                isDense: true,
                prefixText: '\$ ',
                border: const OutlineInputBorder(),
                hintText: state.running ? 'Command' : 'Start a shell first',
              ),
              onSubmitted: (_) => _run(),
            ),
          ),
        ],
      ),
    );
  }
}
