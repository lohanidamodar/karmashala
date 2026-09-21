import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/tokens.dart';
import 'package:agent_cli/process.dart';
import '../application/changes_providers.dart';
import '../application/git_providers.dart';
import '../application/worktree_creation_tracker.dart';
import 'worktree_creation_view.dart';

/// What the dialog was asked for.
class WorktreeRequest {
  const WorktreeRequest({
    required this.name,
    required this.branch,
    this.baseRef,
  });

  /// The folder name under the repository's `.karmashala-worktrees` sibling.
  final String name;

  /// The branch git creates with it.
  final String branch;

  /// What the branch starts from, or null for the repository's HEAD — null
  /// rather than `'HEAD'`, so an unstated base does not look like a stated one.
  final String? baseRef;
}

/// A worktree on its own, not only as a side effect of starting a session.
/// Through [WorktreeService.createForSession], so it gets the setup too.
Future<void> showWorktreeCreateDialog(
  BuildContext context,
  WidgetRef ref,
  EnvironmentPath repo,
) async {
  // Taken before the dialog: looking the messenger up across the await is the
  // lint's own case.
  final messenger = ScaffoldMessenger.maybeOf(context);
  final request = await showDialog<WorktreeRequest>(
    context: context,
    builder: (context) => const _WorktreeCreateDialog(),
  );
  if (request == null || !context.mounted) return;
  final tracker = WorktreeCreationTracker(repo: repo);
  final work = ref
      .read(worktreeServiceProvider)
      .createForSession(
        repo: repo,
        worktreeName: request.name,
        branch: request.branch,
        baseRef: request.baseRef,
        tracker: tracker,
      );
  // Its stages while it runs, and the lever that stops it. Closes itself on
  // success; a failure stays up with the stage output that explains it.
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => WorktreeCreationDialog(tracker: tracker, work: work),
    ),
  );
  try {
    final worktree = await work;
    // The list is read on demand, never on a tick, so a create has to say the
    // answer is stale.
    ref.invalidate(repoWorktreesProvider);
    messenger?.showSnackBar(
      SnackBar(content: Text('Created ${worktree.path.path}')),
    );
  } on Object catch (error) {
    // git's own words: "could not create worktree" would hide the one thing
    // worth reading.
    messenger?.showSnackBar(SnackBar(content: Text('$error')));
  }
}

/// A worktree creation's stages, with Cancel while it can still be stopped.
class WorktreeCreationDialog extends StatefulWidget {
  const WorktreeCreationDialog({
    required this.tracker,
    required this.work,
    super.key,
  });

  final WorktreeCreationTracker tracker;
  final Future<Object?> work;

  @override
  State<WorktreeCreationDialog> createState() => _WorktreeCreationDialogState();
}

class _WorktreeCreationDialogState extends State<WorktreeCreationDialog> {
  bool _ended = false;

  @override
  void initState() {
    super.initState();
    widget.work.then(
      (_) {
        if (mounted) Navigator.of(context).pop();
      },
      onError: (Object _) {
        if (mounted) setState(() => _ended = true);
      },
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Creating worktree'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: WorktreeCreationLiveView(tracker: widget.tracker),
      ),
    ),
    actions: [
      if (_ended)
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        )
      else
        TextButton(
          onPressed: () {
            widget.tracker.cancel();
            setState(() {});
          },
          child: Text(widget.tracker.isCancelled ? 'Cancelling…' : 'Cancel'),
        ),
    ],
  );
}

class _WorktreeCreateDialog extends StatefulWidget {
  const _WorktreeCreateDialog();

  @override
  State<_WorktreeCreateDialog> createState() => _WorktreeCreateDialogState();
}

class _WorktreeCreateDialogState extends State<_WorktreeCreateDialog> {
  final _name = TextEditingController();
  final _branch = TextEditingController();
  final _baseRef = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _branch.dispose();
    _baseRef.dispose();
    super.dispose();
  }

  /// The branch defaults to the folder name, as the session launcher does.
  String get _branchText =>
      _branch.text.trim().isEmpty ? _name.text.trim() : _branch.text.trim();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = _name.text.trim();
    return AlertDialog(
      title: const Text('New worktree'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Name',
                helperText: 'The folder, beside the repository.',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: Insets.md),
            TextField(
              controller: _branch,
              decoration: InputDecoration(
                labelText: 'Branch',
                hintText: name.isEmpty ? null : name,
                helperText: 'Defaults to the name.',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: Insets.md),
            TextField(
              controller: _baseRef,
              decoration: const InputDecoration(
                labelText: 'From (optional)',
                helperText: 'A branch, tag or commit. Blank starts from HEAD.',
              ),
            ),
            const SizedBox(height: Insets.sm),
            Text(
              // Said before it happens: it is the difference between this and a
              // bare `git worktree add`.
              'The repository’s post-create setup runs on it, so the tree is '
              'buildable when it appears.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: name.isEmpty
              ? null
              : () => Navigator.of(context).pop(
                  WorktreeRequest(
                    name: name,
                    branch: _branchText,
                    baseRef: _baseRef.text.trim().isEmpty
                        ? null
                        : _baseRef.text.trim(),
                  ),
                ),
          child: const Text('Create'),
        ),
      ],
    );
  }
}
