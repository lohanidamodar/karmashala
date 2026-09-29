/// The commit message, the commit, and the branch this checkout is on — the
/// top of a source-control pane.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_git/git.dart' show GitPresence;

import '../application/changes_providers.dart';
import '../application/commit_drafts.dart';
import '../application/remote_links.dart';
import '../application/working_copy_controller.dart';
import 'pull_request_dialog.dart';

/// The message field, the Commit button and what the last verb had to say.
/// Drawn above the file list; the branch row sits above this one.
class CommitBox extends ConsumerStatefulWidget {
  const CommitBox({super.key});

  @override
  ConsumerState<CommitBox> createState() => _CommitBoxState();
}

class _CommitBoxState extends ConsumerState<CommitBox> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  /// Held rather than read through `ref`: the last save happens in [dispose],
  /// where a `ref` belonging to an unmounted widget is unsafe — and a `late
  /// final` would only move the same read there.
  CommitDrafts? _drafts;

  @override
  void initState() {
    super.initState();
    _drafts = ref.read(commitDraftsProvider.notifier);
  }

  /// Which checkout the field currently holds a draft for, so switching
  /// checkouts swaps drafts instead of carrying one message to another tree.
  String? _draftKey;

  @override
  void dispose() {
    _save();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _save() {
    final key = _draftKey;
    if (key == null) return;
    _drafts?.put(key, _controller.text);
  }

  void _pointAt(String? key) {
    if (key == _draftKey) return;
    _save();
    _draftKey = key;
    _controller.text = key == null
        ? ''
        : (ref.read(commitDraftsProvider)[key] ?? '');
  }

  Future<void> _commit({required bool all}) async {
    final message = _controller.text;
    await ref
        .read(workingCopyControllerProvider.notifier)
        .commit(message, all: all);
    if (!mounted) return;
    // Only a commit that happened clears the message: a hook that refused one
    // is about to be tried again, and retyping it is the punishment.
    if (ref.read(workingCopyControllerProvider).error == null) {
      _controller.clear();
      _save();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final checkout = ref.watch(viewedCheckoutProvider);
    _pointAt(
      checkout == null ? null : '${checkout.environmentId}␟${checkout.path}',
    );
    final state = ref.watch(workingCopyControllerProvider);
    final staged = ref.watch(
      repositoryChangesProvider.select(
        (changes) =>
            changes.asData?.value.where((file) => file.staged).length ?? 0,
      ),
    );
    final anyChange = ref.watch(
      repositoryChangesProvider.select(
        (changes) => changes.asData?.value.isNotEmpty ?? false,
      ),
    );
    if (checkout == null) return const SizedBox.shrink();
    // Nothing here can act on a folder git does not know: no branch to show,
    // nothing to pull, push or commit.
    if (ref.watch(checkoutGitPresenceProvider(checkout)).asData?.value ==
        GitPresence.notARepository) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(Insets.sm, 0, Insets.sm, Insets.xs),
        child: _Saying(text: 'Not a git repository'),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Insets.sm, Insets.xs, Insets.sm, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _BranchRow(),
          const SizedBox(height: Insets.xs),
          // Ctrl/Cmd+Enter commits, as every editor's commit box does; Enter
          // alone is a newline, because a commit body is normal.
          Shortcuts(
            shortcuts: {
              LogicalKeySet(
                LogicalKeyboardKey.control,
                LogicalKeyboardKey.enter,
              ): const _CommitIntent(),
              LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.enter):
                  const _CommitIntent(),
            },
            child: Actions(
              actions: {
                _CommitIntent: CallbackAction<_CommitIntent>(
                  onInvoke: (_) {
                    if (!state.isBusy) _commit(all: staged == 0);
                    return null;
                  },
                ),
              },
              child: TextField(
                controller: _controller,
                focusNode: _focus,
                maxLines: 3,
                minLines: 1,
                style: theme.textTheme.bodySmall,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: staged == 0
                      ? 'Message (commits everything)'
                      : 'Message ($staged staged)',
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
          ),
          const SizedBox(height: Insets.xs),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(AppIcons.check, size: Chrome.iconSmall),
                  label: Text(staged == 0 ? 'Commit all' : 'Commit'),
                  onPressed: state.isBusy || !anyChange
                      ? null
                      : () => _commit(all: staged == 0),
                ),
              ),
              if (staged > 0)
                IconButton(
                  tooltip: 'Commit everything, staged or not',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(AppIcons.listChecks, size: Chrome.icon),
                  onPressed: state.isBusy ? null : () => _commit(all: true),
                ),
            ],
          ),
          if (state.busy case final busy?) _Saying(text: '$busy…'),
          if (state.error case final error?)
            Padding(
              padding: const EdgeInsets.only(top: Insets.xs),
              child: DesktopErrorBanner(error),
            ),
          if (state.note case final note?) _Saying(text: note),
        ],
      ),
    );
  }
}

class _CommitIntent extends Intent {
  const _CommitIntent();
}

/// One quiet line under the button: what is happening, or what just did.
class _Saying extends StatelessWidget {
  const _Saying({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Insets.xs),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// The branch, how far it is from its upstream, and the one button that acts
/// on that: publish when there is no upstream, pull when behind, push when
/// ahead. The rest are in the menu beside it.
class _BranchRow extends ConsumerWidget {
  const _BranchRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final status = ref.watch(workingTreeStatusProvider).asData?.value;
    final busy = ref.watch(
      workingCopyControllerProvider.select((state) => state.isBusy),
    );
    final copy = ref.read(workingCopyControllerProvider.notifier);
    final branch = status?.branch;
    final ahead = status?.aheadOfUpstream ?? 0;
    final behind = status?.behindUpstream ?? 0;
    // Null upstream and null counts are different answers: no upstream at all
    // versus one git could not compare against. Only the first offers Publish.
    final unpublished = status != null && status.upstream == null;
    void act(String value) => switch (value) {
      'fetch' => copy.fetch(),
      'pull_rebase' => copy.pull(rebase: true),
      'pull_merge' => copy.pull(merge: true),
      _ => _openPullRequest(context, ref, branch),
    };

    return Row(
      children: [
        Icon(
          AppIcons.gitBranch,
          size: Chrome.iconSmall,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: Insets.xs),
        Expanded(
          child: Tooltip(
            message: status?.upstream == null
                ? 'No upstream branch'
                : 'Tracking ${status!.upstream}',
            child: Text(
              branch ?? 'detached',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: MonoStyles.small,
            ),
          ),
        ),
        if (behind > 0 || ahead > 0) ...[
          Text(
            [if (behind > 0) '↓$behind', if (ahead > 0) '↑$ahead'].join(' '),
            style: MonoStyles.small.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: Insets.xs),
        ],
        if (unpublished && branch != null)
          TextButton(
            onPressed: busy ? null : () => copy.publish(branch: branch),
            child: const Text('Publish'),
          )
        else ...[
          IconButton(
            tooltip: behind > 0 ? 'Pull $behind' : 'Pull',
            visualDensity: VisualDensity.compact,
            icon: const Icon(AppIcons.arrowDown, size: Chrome.iconSmall),
            onPressed: busy ? null : () => copy.pull(),
          ),
          IconButton(
            tooltip: ahead > 0 ? 'Push $ahead' : 'Push',
            visualDensity: VisualDensity.compact,
            icon: const Icon(AppIcons.arrowUp, size: Chrome.iconSmall),
            onPressed: busy ? null : copy.push,
          ),
        ],
        RowContextMenu(
          menuLabel: 'Git actions',
          itemBuilder: _gitActions,
          onSelected: act,
          builder: (anchor) => IconButton(
            tooltip: 'Git actions',
            visualDensity: VisualDensity.compact,
            icon: const Icon(
              AppIcons.dotsThreeVertical,
              size: Chrome.iconSmall,
            ),
            // The same menu the right-click opens, under the button.
            onPressed: busy
                ? null
                : () async {
                    final picked = await showDesktopMenuUnder(
                      anchor,
                      _gitActions(),
                    );
                    if (picked != null) act(picked);
                  },
          ),
        ),
      ],
    );
  }

  static List<PopupMenuEntry<String>> _gitActions() => [
    DesktopMenuItem(
      value: 'fetch',
      label: 'Fetch',
      icon: AppIcons.arrowsClockwise,
    ),
    DesktopMenuItem(
      value: 'pull_rebase',
      label: 'Pull (rebase)',
      icon: AppIcons.arrowDown,
    ),
    DesktopMenuItem(
      value: 'pull_merge',
      label: 'Pull (merge)',
      icon: AppIcons.gitMerge,
    ),
    const DesktopMenuDivider(),
    DesktopMenuItem(
      value: 'pr',
      label: 'Open a pull request…',
      icon: AppIcons.arrowSquareOut,
    ),
  ];
}

/// Asks for a title and a body, opens the request, and offers the URL it comes
/// back with. Nothing is opened in a browser without being asked: a pull
/// request is a public act, and so is putting one on screen.
Future<void> _openPullRequest(
  BuildContext context,
  WidgetRef ref,
  String? branch,
) async {
  final copy = ref.read(workingCopyControllerProvider.notifier);
  final head = ref.read(recentCommitsProvider).asData?.value.firstOrNull;
  final asked = await PullRequestDialog.ask(
    context,
    branch: branch ?? 'this branch',
    title: head?.subject ?? '',
  );
  if (asked == null) return;
  final url = await copy.createPullRequest(
    title: asked.title,
    body: asked.body,
  );
  if (url == null || url.isEmpty || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(
    SnackBar(
      content: Text(url),
      action: SnackBarAction(
        label: 'Open',
        onPressed: () => ref.read(openExternalUrlProvider)(url),
      ),
    ),
  );
}
