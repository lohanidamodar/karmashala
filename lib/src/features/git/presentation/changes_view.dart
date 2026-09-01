import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../sessions/application/delivery_providers.dart';
import '../application/changes_providers.dart';
import '../application/diff_annotations.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../data/git_diff_parsing.dart';
import 'diff_line_tile.dart';
import 'remote_link.dart';
import '../domain/diff_line.dart';
import '../domain/file_change.dart';

/// Read-only Git change review, desktop-style: a vertical list of changed files,
/// each expandable to reveal its unified diff inline, and openable full-screen
/// for a wide, scrollable read. Git is the source of truth; there is no editor.
class ChangesView extends ConsumerStatefulWidget {
  const ChangesView({required this.repositoryName, super.key});

  final String repositoryName;

  @override
  ConsumerState<ChangesView> createState() => _ChangesViewState();
}

class _ChangesViewState extends ConsumerState<ChangesView> {
  final _expanded = <String>{};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final changes = ref.watch(repositoryChangesProvider);
    final repositoryId = ref.watch(selectedRepositoryIdProvider);
    final sessionId = ref.watch(selectedSessionIdProvider);
    final annotations = ref
        .watch(diffAnnotationsProvider)
        .where((item) => item.repositoryId == repositoryId)
        .toList();

    // What this repository's work is called on the forge, so a branch, a
    // commit or a pull request in view is one click from the page that owns it.
    final delivery = repositoryId == null
        ? null
        : ref.watch(repositoryDeliveryProvider(repositoryId)).asData?.value;
    final head = ref.watch(recentCommitsProvider).asData?.value.firstOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Insets.md,
            Insets.xs,
            4,
            Insets.xs,
          ),
          child: Row(
            children: [
              // Every part of the header line is flexible, so a long branch
              // name in a narrow panel ellipsises rather than overflowing —
              // this row sits in a side panel that can be dragged to 250px.
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        'Changes',
                        style: theme.textTheme.labelSmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (delivery?.branch case final branch?) ...[
                      const SizedBox(width: Insets.sm),
                      Flexible(
                        child: RemoteLink(
                          text: branch,
                          url: delivery!.remote?.branchUrl(branch),
                          style: theme.textTheme.labelSmall,
                        ),
                      ),
                    ],
                    if (head != null) ...[
                      const SizedBox(width: Insets.sm),
                      Flexible(
                        child: RemoteLink(
                          text: shortSha(head.sha),
                          // Drawn plainly when there is no remote — a commit
                          // without one is still a commit.
                          url: delivery?.remote?.commitUrl(head.sha),
                          style: theme.textTheme.labelSmall,
                          tooltip: head.subject,
                        ),
                      ),
                    ],
                    if (delivery?.pullRequest case final pr?) ...[
                      const SizedBox(width: Insets.sm),
                      Flexible(
                        child: RemoteLink(
                          text: '#${pr.number}',
                          url: pr.url,
                          style: theme.textTheme.labelSmall,
                          tooltip: pr.title.isEmpty ? pr.url : pr.title,
                          icon: true,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              changes.maybeWhen(
                data: (files) => files.isEmpty
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Text(
                          '${files.length}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                orElse: () => const SizedBox.shrink(),
              ),
              IconButton(
                tooltip: 'Refresh',
                visualDensity: VisualDensity.compact,
                icon: const Icon(AppIcons.arrowsClockwise, size: 16),
                onPressed: () => ref.invalidate(repositoryChangesProvider),
              ),
              if (annotations.isNotEmpty)
                IconButton(
                  tooltip: sessionId == null
                      ? 'Select a session to send ${annotations.length} review comments'
                      : 'Send ${annotations.length} review comments to agent',
                  icon: Badge(
                    label: Text('${annotations.length}'),
                    child: const Icon(AppIcons.chatCircleDots, size: 16),
                  ),
                  onPressed: sessionId == null || repositoryId == null
                      ? null
                      : () async {
                          await ref
                              .read(sessionActionsProvider)
                              .continueSession(
                                sessionId,
                                buildDiffFeedbackPrompt(annotations),
                              );
                          ref
                              .read(diffAnnotationsProvider.notifier)
                              .clearRepository(repositoryId);
                        },
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: changes.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => _ErrorBox(message: '$e'),
            data: (files) => files.isEmpty
                ? Center(
                    child: Text(
                      'No working-tree changes.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: Insets.xs),
                    itemCount: files.length,
                    itemBuilder: (context, index) {
                      final file = files[index];
                      return _ChangedFileSection(
                        file: file,
                        expanded: _expanded.contains(file.path),
                        onToggle: () => setState(() {
                          if (!_expanded.remove(file.path)) {
                            _expanded.add(file.path);
                          }
                        }),
                        onFullscreen: () => _openFullscreen(context, file),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  void _openFullscreen(BuildContext context, FileChange file) {
    ref.read(selectedChangeFileProvider.notifier).select(file.path);
    showDialog<void>(
      context: context,
      builder: (_) => _DiffFullscreenDialog(file: file),
    );
  }
}

class _ChangedFileSection extends ConsumerWidget {
  const _ChangedFileSection({
    required this.file,
    required this.expanded,
    required this.onToggle,
    required this.onFullscreen,
  });

  final FileChange file;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onFullscreen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
            child: Row(
              children: [
                Icon(
                  expanded ? AppIcons.caretDown : AppIcons.caretRight,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                Icon(
                  _iconFor(file.type),
                  size: 14,
                  color: _colorFor(file.type, context),
                ),
                const SizedBox(width: Insets.xs),
                Expanded(
                  child: Text(
                    file.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: kMonoFamily,
                      fontSize: 12,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Open full screen',
                  visualDensity: VisualDensity.compact,
                  iconSize: 14,
                  constraints: const BoxConstraints(
                    minWidth: 26,
                    minHeight: 26,
                  ),
                  padding: EdgeInsets.zero,
                  icon: const Icon(AppIcons.arrowsOutSimple),
                  onPressed: onFullscreen,
                ),
              ],
            ),
          ),
        ),
        if (expanded)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: _InlineDiff(path: file.path, wrap: true),
          ),
        const Divider(height: 1),
      ],
    );
  }
}

/// Renders a file's unified diff. [wrap] softwraps long lines (for the narrow
/// sidebar); when false the diff scrolls horizontally (full-screen view).
class _InlineDiff extends ConsumerWidget {
  const _InlineDiff({required this.path, this.wrap = false});

  final String path;
  final bool wrap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final diff = ref.watch(fileDiffByPathProvider(path));
    return diff.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(Insets.md),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      error: (e, _) => _ErrorBox(message: '$e'),
      data: (text) {
        final lines = parseUnifiedDiff(text);
        if (lines.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(Insets.md),
            child: Text(
              'No textual diff (binary or untracked file).',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          );
        }
        final list = ListView.builder(
          primary: false,
          padding: const EdgeInsets.symmetric(vertical: Insets.xs),
          itemCount: lines.length,
          itemBuilder: (context, index) => _DiffLineTile(
            path: path,
            diffIndex: index,
            line: lines[index],
            wrap: wrap,
          ),
        );
        if (wrap) return list;
        // Full-screen: let long code lines scroll horizontally.
        return Scrollbar(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(width: 1400, child: list),
          ),
        );
      },
    );
  }
}

class _DiffFullscreenDialog extends StatelessWidget {
  const _DiffFullscreenDialog({required this.file});
  final FileChange file;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1200, maxHeight: 900),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.lg,
                Insets.sm,
                8,
                Insets.sm,
              ),
              child: Row(
                children: [
                  Icon(_iconFor(file.type), size: 16),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    child: Text(
                      file.path,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontFamily: kMonoFamily,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Consumer(
                    builder: (context, ref, _) => IconButton(
                      tooltip: 'Copy diff',
                      icon: const Icon(AppIcons.copySimple, size: 18),
                      onPressed: () async {
                        final diff = await ref.read(
                          fileDiffByPathProvider(file.path).future,
                        );
                        await Clipboard.setData(ClipboardData(text: diff));
                      },
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(AppIcons.x, size: 18),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(child: _InlineDiff(path: file.path)),
          ],
        ),
      ),
    );
  }
}

class _DiffLineTile extends ConsumerWidget {
  const _DiffLineTile({
    required this.path,
    required this.diffIndex,
    required this.line,
    this.wrap = false,
  });
  final String path;
  final int diffIndex;
  final DiffLine line;
  final bool wrap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final repositoryId = ref.watch(selectedRepositoryIdProvider);
    final annotation = ref
        .watch(diffAnnotationsProvider)
        .where(
          (item) =>
              item.repositoryId == repositoryId &&
              item.path == path &&
              item.diffIndex == diffIndex,
        )
        .firstOrNull;
    // The drawing lives in `DiffLineTile`, shared with the agent-edit diff in
    // the transcript; what stays here is the one thing only this panel has, the
    // review comment hung off the end of the row.
    final commentable =
        line.kind == DiffLineKind.added ||
        line.kind == DiffLineKind.removed ||
        line.kind == DiffLineKind.context;
    return DiffLineTile(
      line: line,
      wrap: wrap,
      trailing: commentable
          ? IconButton(
              tooltip: annotation == null
                  ? 'Add review comment'
                  : annotation.comment,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              padding: EdgeInsets.zero,
              icon: Icon(
                annotation == null
                    ? AppIcons.chatCircle
                    : AppIcons.chatCircleDots,
                size: Chrome.iconSmall,
                color: annotation == null ? null : scheme.tertiary,
              ),
              onPressed: repositoryId == null
                  ? null
                  : () =>
                        _editAnnotation(context, ref, repositoryId, annotation),
            )
          : null,
    );
  }

  Future<void> _editAnnotation(
    BuildContext context,
    WidgetRef ref,
    String repositoryId,
    DiffAnnotation? existing,
  ) async {
    final controller = TextEditingController(text: existing?.comment);
    final comment = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Review comment'),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: controller,
            autofocus: true,
            minLines: 3,
            maxLines: 8,
            decoration: InputDecoration(
              labelText: '$path · diff line ${diffIndex + 1}',
              helperText: line.text,
            ),
          ),
        ),
        actions: [
          if (existing != null)
            TextButton(
              onPressed: () => Navigator.pop(context, ''),
              child: const Text('Remove'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (comment == null) return;
    final notifier = ref.read(diffAnnotationsProvider.notifier);
    if (comment.isEmpty) {
      notifier.remove(repositoryId, path, diffIndex);
    } else {
      notifier.put(
        DiffAnnotation(
          repositoryId: repositoryId,
          path: path,
          diffIndex: diffIndex,
          line: line,
          comment: comment,
        ),
      );
    }
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
        padding: const EdgeInsets.all(Insets.md),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.error),
        ),
      ),
    );
  }
}

IconData _iconFor(FileChangeType type) => switch (type) {
  FileChangeType.added => AppIcons.plusCircle,
  FileChangeType.deleted => AppIcons.minusCircle,
  FileChangeType.renamed => AppIcons.pencilSimple,
  FileChangeType.untracked => AppIcons.question,
  _ => AppIcons.pencil,
};

Color _colorFor(FileChangeType type, BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  final semantic = SemanticColors.of(context);
  return switch (type) {
    FileChangeType.added => semantic.diffAdded,
    FileChangeType.deleted => semantic.diffRemoved,
    _ => scheme.primary,
  };
}
