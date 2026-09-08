import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/design_tokens.dart';
import '../../environments/domain/environment_path.dart';
import '../application/changes_providers.dart';
import '../application/git_providers.dart';

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

  /// What the branch starts from, or null for the repository's HEAD.
  ///
  /// Null rather than `'HEAD'`: git's own default is what the caller wants when
  /// nobody said, and writing `HEAD` in would make an unstated base look like a
  /// stated one in the argv the test reads.
  final String? baseRef;
}

/// **A worktree on its own**, not only as a side effect of starting a session.
///
/// `worktree_create` could always make one for an agent, and a person could
/// only get one by launching a session into it. That is backwards for the case
/// the tool exists for — somewhere to try something without disturbing the
/// checkout an agent is already editing.
///
/// It goes through [WorktreeService.createForSession], not around it, which is
/// what makes this the same worktree the tool makes rather than one that merely
/// looks like it: the sibling `.karmashala-worktrees/…` path, and — this is the
/// part a hand-rolled `git worktree add` would silently skip — the repository's
/// **post-create setup**, the copy that makes the tree buildable. The method is
/// named for its first caller and its body is not about sessions.
Future<void> showWorktreeCreateDialog(
  BuildContext context,
  WidgetRef ref,
  EnvironmentPath repo,
) async {
  // Taken before the dialog, not after: the messenger is what says what
  // happened, and looking it up across the await is the lint's own case.
  final messenger = ScaffoldMessenger.maybeOf(context);
  final request = await showDialog<WorktreeRequest>(
    context: context,
    builder: (context) => const _WorktreeCreateDialog(),
  );
  if (request == null) return;
  try {
    final worktree = await ref
        .read(worktreeServiceProvider)
        .createForSession(
          repo: repo,
          worktreeName: request.name,
          branch: request.branch,
          baseRef: request.baseRef,
        );
    // The list is read on demand, never on a tick, so the one thing that has to
    // happen after a create is to say the answer is stale.
    ref.invalidate(repoWorktreesProvider);
    messenger?.showSnackBar(
      SnackBar(content: Text('Created ${worktree.path.path}')),
    );
  } on Object catch (error) {
    // git's own words. "Could not create worktree" would hide the one thing
    // worth reading — a branch that already exists, a base ref that does not.
    messenger?.showSnackBar(SnackBar(content: Text('$error')));
  }
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

  /// The branch defaults to the folder name, which is what a person means the
  /// first time and what the session launcher already does.
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
              // Said before it happens, because it is the difference between
              // this and a bare `git worktree add`.
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
