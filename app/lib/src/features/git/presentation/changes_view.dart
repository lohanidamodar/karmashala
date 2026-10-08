import '../data/git_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:agent_cli/process.dart';
import 'package:path/path.dart' as p;
import '../application/diff_tab_actions.dart';
import 'commit_box.dart';
import 'diff_counts.dart';
import '../../sessions/application/delivery_providers.dart';
import '../application/changes_providers.dart';
import '../application/review_threads.dart';
import '../application/working_copy_controller.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/application/session_ui_providers.dart';
import 'package:karmashala_git/git.dart';
import 'diff_view.dart';
import 'remote_link.dart';

part 'changes_view/changed_files.dart';
part 'changes_view/file_rows.dart';
part 'changes_view/row_actions.dart';

/// Read-only Git change review: what changed, listed. Reading a change happens
/// in a workbench tab ([DiffTabView]), which has the room for it.
class ChangesView extends ConsumerWidget {
  const ChangesView({required this.repositoryName, super.key});

  final String repositoryName;

  /// Builds of the file rows, counted so a cost test can prove a header action
  /// repaints without the list.
  @visibleForTesting
  static int debugFileRowBuildCount = 0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Nothing here watches a provider: each header action subscribes to the one
    // thing it draws, so a commit does not repaint every file row.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PaneHeader(
          icon: AppIcons.gitDiff,
          title: 'Changes',
          actions: [
            // Flexible so a long branch ellipsises: this side panel can be
            // dragged down to 240px.
            const Flexible(child: _DeliveryLinks()),
            const _ChangedFileCount(),
            const _AbortMergeButton(),
            IconButton(
              tooltip: 'Refresh',
              visualDensity: VisualDensity.compact,
              icon: const Icon(AppIcons.arrowsClockwise, size: Chrome.icon),
              // The probe as well, or a folder that has just had `git init` run
              // in it would keep answering from the cached verdict.
              onPressed: () {
                ref.invalidate(checkoutGitPresenceProvider);
                ref.invalidate(repositoryChangesProvider);
              },
            ),
            const _SendReviewThreadsButton(),
          ],
        ),
        // Flexible, not fixed: this panel is dragged down to 240px, and the
        // file list must not be squeezed out by a commit box that will not
        // give way. It scrolls inside whatever it is left.
        const Flexible(child: CommitBox()),
        const Expanded(child: _ChangedFiles()),
      ],
    );
  }
}

/// Forge links for the branch, head commit and pull request in view. Its own
/// widget because only it watches the delivery and commit log, which poll.
class _DeliveryLinks extends ConsumerWidget {
  const _DeliveryLinks();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final repositoryId = ref.watch(selectedRepositoryIdProvider);
    final delivery = repositoryId == null
        ? null
        : ref.watch(repositoryDeliveryProvider(repositoryId)).asData?.value;
    // Only the tip is drawn, so only the tip is subscribed to: the other seven
    // commits the provider returns move without touching this row.
    final head = ref.watch(
      recentCommitsProvider.select((v) => v.asData?.value.firstOrNull),
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
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
              // Drawn plainly when there is no remote — a commit without one
              // is still a commit.
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
    );
  }
}

/// How many files changed. Subscribed to the count alone, so the list growing a
/// hunk redraws nothing here.
class _ChangedFileCount extends ConsumerWidget {
  const _ChangedFileCount();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(
      repositoryChangesProvider.select(
        (v) => changedFileCount(v.asData?.value ?? const []),
      ),
    );
    if (count == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: Insets.xs),
      child: Text(
        '$count',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// `git merge --abort` on the working tree being read, behind a confirm. Shown
/// only when there is something to abort: an undo button beside a clean tree
/// offers to discard work that is not there.
class _AbortMergeButton extends ConsumerWidget {
  const _AbortMergeButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final checkout = ref.watch(viewedCheckoutProvider);
    if (checkout == null) return const SizedBox.shrink();
    // Hidden while the reading is pending or errored too: this button destroys
    // work, so it appears on evidence and never on a guess.
    if (ref.watch(mergeInProgressProvider).asData?.value != true) {
      return const SizedBox.shrink();
    }
    return IconButton(
      tooltip: 'Abort merge',
      visualDensity: VisualDensity.compact,
      icon: const Icon(AppIcons.arrowCounterClockwise, size: Chrome.icon),
      onPressed: () => _press(context, ref, checkout),
    );
  }

  Future<void> _press(
    BuildContext context,
    WidgetRef ref,
    EnvironmentPath checkout,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Abort the merge in progress?'),
        content: const Text(
          'git merge --abort puts the working tree back to the commit the '
          'merge started from. Every conflict resolution made since then is '
          'discarded.\n\n'
          'Commits are untouched, and if no merge is in progress nothing '
          'changes at all.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Abort merge'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final restored = await ref.read(gitDataProvider).abortMerge(checkout);
    // Only on the half that rewrote files; an abort that found nothing to undo
    // changed no file.
    if (restored) ref.invalidate(repositoryChangesProvider);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          restored
              ? 'Merge aborted. The working tree is back to before it started.'
              : 'There was no merge to abort; nothing changed.',
        ),
      ),
    );
  }
}

/// Sends the should-fix review threads to the session on screen. Watches the
/// index here so a reply over MCP repaints one badge, not the file list.
class _SendReviewThreadsButton extends ConsumerWidget {
  const _SendReviewThreadsButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final threads =
        ref.watch(repositoryReviewThreadsProvider).asData?.value ??
        ReviewThreadIndex.empty;
    final pending = threads.pending;
    if (pending.isEmpty) return const SizedBox.shrink();

    final sessionId = ref.watch(selectedSessionIdProvider);
    final repositoryId = ref.watch(selectedRepositoryIdProvider);
    return IconButton(
      // "Should fix", not "every comment": a thread nobody has triaged is a
      // claim, and sending it would hand an agent work no human asked for.
      tooltip: sessionId == null
          ? 'Select a session to send ${pending.length} review comments '
                'marked should-fix'
          : 'Send ${pending.length} should-fix review comments to the agent',
      icon: Badge(
        label: Text('${pending.length}'),
        child: const Icon(AppIcons.chatCircleDots, size: Chrome.icon),
      ),
      onPressed: sessionId == null || repositoryId == null
          ? null
          : () async {
              // Sending clears nothing: the thread stays should-fix until
              // somebody looks at the code and decides it is done.
              await ref
                  .read(sessionActionsProvider)
                  .continueSession(sessionId, buildReviewThreadPrompt(pending));
            },
    );
  }
}
