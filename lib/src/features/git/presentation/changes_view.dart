import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/changes_providers.dart';
import '../data/git_diff_parsing.dart';
import '../domain/diff_line.dart';
import '../domain/file_change.dart';

/// Read-only Git change review: changed files on the left, the selected file's
/// unified diff on the right. Git is the source of truth; there is no editor.
class ChangesView extends ConsumerWidget {
  const ChangesView({required this.repositoryName, super.key});

  final String repositoryName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final changes = ref.watch(repositoryChangesProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Back to repositories',
                icon: const Icon(Icons.arrow_back, size: 18),
                onPressed: () {
                  ref.read(selectedChangeFileProvider.notifier).select(null);
                  ref.read(selectedRepositoryIdProvider.notifier).select(null);
                },
              ),
              Expanded(
                child: Text(
                  'Changes · $repositoryName',
                  style: theme.textTheme.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh, size: 18),
                onPressed: () => ref.invalidate(repositoryChangesProvider),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 240,
                child: changes.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => _ErrorBox(message: '$e'),
                  data: (files) => _FileList(files: files),
                ),
              ),
              const VerticalDivider(width: 1),
              const Expanded(child: _DiffPane()),
            ],
          ),
        ),
      ],
    );
  }
}

class _FileList extends ConsumerWidget {
  const _FileList({required this.files});
  final List<FileChange> files;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (files.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('No working-tree changes.', textAlign: TextAlign.center),
        ),
      );
    }
    final selected = ref.watch(selectedChangeFileProvider);
    return ListView.builder(
      itemCount: files.length,
      itemBuilder: (context, index) {
        final file = files[index];
        return ListTile(
          dense: true,
          selected: file.path == selected,
          leading: Icon(
            _iconFor(file.type),
            size: 16,
            color: _colorFor(file.type, context),
          ),
          title: Text(
            file.path,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          subtitle: Text(_labelFor(file)),
          onTap: () =>
              ref.read(selectedChangeFileProvider.notifier).select(file.path),
        );
      },
    );
  }

  IconData _iconFor(FileChangeType type) => switch (type) {
    FileChangeType.added => Icons.add_circle_outline,
    FileChangeType.deleted => Icons.remove_circle_outline,
    FileChangeType.renamed => Icons.drive_file_rename_outline,
    FileChangeType.untracked => Icons.help_outline,
    _ => Icons.edit_outlined,
  };

  Color _colorFor(FileChangeType type, BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return switch (type) {
      FileChangeType.added => Colors.green,
      FileChangeType.deleted => scheme.error,
      _ => scheme.primary,
    };
  }

  String _labelFor(FileChange file) {
    final parts = <String>[
      if (file.staged) 'staged',
      if (file.unstaged) 'unstaged',
    ];
    return '${file.type.name}${parts.isEmpty ? '' : ' · ${parts.join('/')}'}';
  }
}

class _DiffPane extends ConsumerWidget {
  const _DiffPane();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final file = ref.watch(selectedChangeFileProvider);
    if (file == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('Select a file to view its diff.'),
        ),
      );
    }
    final diff = ref.watch(fileDiffProvider);
    return diff.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _ErrorBox(message: '$e'),
      data: (text) {
        final lines = parseUnifiedDiff(text);
        if (lines.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('No textual diff (binary or untracked file).'),
            ),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(8),
          itemCount: lines.length,
          itemBuilder: (context, index) => _DiffLineTile(line: lines[index]),
        );
      },
    );
  }
}

class _DiffLineTile extends StatelessWidget {
  const _DiffLineTile({required this.line});
  final DiffLine line;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (Color? bg, Color? fg) = switch (line.kind) {
      DiffLineKind.added => (Colors.green.withValues(alpha: 0.15), null),
      DiffLineKind.removed => (scheme.error.withValues(alpha: 0.12), null),
      DiffLineKind.hunk => (
        scheme.primary.withValues(alpha: 0.10),
        scheme.primary,
      ),
      DiffLineKind.meta => (null, scheme.onSurfaceVariant),
      DiffLineKind.context => (null, null),
    };
    return Container(
      color: bg,
      width: double.infinity,
      child: Text(
        line.text.isEmpty ? ' ' : line.text,
        style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: fg),
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.error),
        ),
      ),
    );
  }
}
