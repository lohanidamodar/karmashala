import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../git/application/remote_links.dart';
import '../../git/presentation/remote_link.dart';
import '../../github/domain/pull_request_snapshot.dart';
import '../application/delivery_providers.dart';
import '../application/session_actions.dart';
import '../application/session_archive_service.dart';
import '../application/session_handoff_service.dart';
import '../application/session_providers.dart';
import '../domain/delivery_action.dart';
import '../domain/delivery_stage.dart';
import '../domain/session_delivery.dart';
import 'continue_with_dialog.dart';

/// One strip, above the message box, carrying a session's whole delivery
/// lifecycle: where the work stands, and the next sensible thing to do with it.
///
/// It replaces Loop 33's handoff row and keeps its central decision intact —
/// **the steps the agent should take are prompts.** Commit, push, open a pull
/// request and merge are sentences typed into the running session through the
/// same `continueSession` the composer uses; there is no second write path, no
/// confirm dialog, and no error surface, because whatever goes wrong is
/// reported in the transcript by the thing that knows what happened.
///
/// What the app does itself is drawn no differently but behaves differently:
/// opening the pull request or its checks hands a URL to the browser, and
/// archiving the worktree is a destructive local operation that asks first and
/// reports what it did.
class DeliveryStrip extends ConsumerStatefulWidget {
  const DeliveryStrip({required this.sessionId, super.key});

  final String sessionId;

  @override
  ConsumerState<DeliveryStrip> createState() => _DeliveryStripState();
}

class _DeliveryStripState extends ConsumerState<DeliveryStrip> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send(DeliveryAction action) => _run(() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(sessionActionsProvider)
          .continueSession(widget.sessionId, action.prompt!);
    } catch (e) {
      // The one failure that means the prompt never left the app at all.
      messenger.showSnackBar(
        SnackBar(content: Text(e is StateError ? e.message : '$e')),
      );
    }
  });

  Future<void> _open(String? url) => _run(() async {
    if (url == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final opened = await ref.read(openExternalUrlProvider)(url);
    if (!opened) {
      messenger.showSnackBar(SnackBar(content: Text('Could not open $url')));
    }
  });

  Future<void> _archive() => _run(() async {
    final messenger = ScaffoldMessenger.of(context);
    final worktree = ref
        .read(sessionDaoProvider)
        .getById(widget.sessionId)
        ?.worktree;
    if (worktree == null) return;

    final confirmed = await _confirm(
      title: 'Archive this worktree?',
      body:
          'The directory ${worktree.path} is removed.\n\n'
          'The transcript, review notes and checkpoints are kept, and so is '
          'the branch.',
      action: 'Archive',
    );
    if (confirmed != true) return;

    final service = ref.read(sessionArchiveServiceProvider);
    var outcome = await service.archive(widget.sessionId);
    if (outcome.refusal == ArchiveRefusal.uncommittedChanges) {
      // A second, separate confirmation, because this one destroys work no
      // branch holds — and it is asked about *this* session rather than set as
      // a mode.
      final discard = await _confirm(
        title: 'Discard uncommitted work?',
        body:
            '${outcome.message}\n\n'
            'They are in no commit and no branch, so this cannot be undone.',
        action: 'Discard and archive',
        destructive: true,
      );
      if (discard != true) {
        messenger.showSnackBar(SnackBar(content: Text(outcome.message)));
        return;
      }
      outcome = await service.archive(
        widget.sessionId,
        discardUncommitted: true,
      );
    }
    messenger.showSnackBar(SnackBar(content: Text(outcome.message)));
  });

  Future<bool?> _confirm({
    required String title,
    required String body,
    required String action,
    bool destructive = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                  )
                : null,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
  }

  void _press(DeliveryAction action, SessionDelivery? delivery) {
    final pr = delivery?.pullRequest;
    switch (action) {
      case DeliveryAction.viewPullRequest:
        _open(pr?.url);
      case DeliveryAction.viewChecks:
        _open(pr?.url == null ? null : '${pr!.url}/checks');
      case DeliveryAction.archive:
        _archive();
      default:
        _send(action);
    }
  }

  @override
  Widget build(BuildContext context) {
    // `.value` keeps the previous answer through a refresh, which is what
    // stops the strip blinking every time the window regains focus: the state
    // line below is drawn only when `delivery != null`, so reading a refresh's
    // `AsyncLoading` as null made the strip lose a row — measured at 131px
    // collapsing to 57px — and everything laid out around it moved.
    final delivery = ref.watch(sessionDeliveryProvider(widget.sessionId)).value;
    final actions = ref.watch(sessionDeliveryActionsProvider(widget.sessionId));
    final canContinue = ref
        .watch(sessionContinuationProvider(widget.sessionId))
        .isPossible;
    if (actions.isEmpty && !canContinue && delivery == null) {
      return const SizedBox.shrink();
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 1),
        if (delivery != null) _DeliveryState(delivery: delivery),
        Padding(
          // Padded on all four sides since Loop 85: the strip is hosted under
          // the terminal as well as above the composer, and there it is the
          // last thing in the column with nothing below to give it room.
          padding: const EdgeInsets.fromLTRB(8, Insets.xs, 8, Insets.xs),
          child: Wrap(
            spacing: Insets.sm,
            runSpacing: Insets.xs,
            children: [
              for (final offered in actions)
                _ActionChip(
                  offered: offered,
                  onPressed: _busy || !offered.isEnabled
                      ? null
                      : () => _press(offered.action, delivery),
                ),
              if (canContinue)
                ActionChip(
                  avatar: const Icon(AppIcons.arrowBendDownRight, size: 14),
                  label: const Text('Continue with…'),
                  tooltip:
                      'Move this session to another agent, or fork it. '
                      'Nothing is launched until you have seen what the next '
                      'agent will be told.',
                  onPressed: _busy
                      ? null
                      : () =>
                            ContinueWithDialog.show(context, widget.sessionId),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The state line: how far the work has got, and the numbers behind that.
class _DeliveryState extends StatelessWidget {
  const _DeliveryState({required this.delivery});

  final SessionDelivery delivery;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final label = theme.textTheme.labelSmall;
    final muted = label?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final stage = delivery.stage;
    final pr = delivery.pullRequest;

    final colour = switch (stage) {
      DeliveryStage.checksFailing => semantic.failure,
      DeliveryStage.checksPassing || DeliveryStage.merged => semantic.idle,
      DeliveryStage.prOpen => semantic.attention,
      _ => semantic.neutral,
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.md, 6, Insets.sm, 0),
      child: Wrap(
        spacing: Insets.sm,
        runSpacing: Insets.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // A dot as well as a colour: state must never be carried by colour
          // alone, and the stage's own name is beside it regardless.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_stageIcon(stage), size: 12, color: colour),
              const SizedBox(width: 4),
              Text(stage.label, style: label?.copyWith(color: colour)),
            ],
          ),
          if (delivery.branch case final branch?)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  AppIcons.gitBranch,
                  size: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 160),
                  child: RemoteLink(
                    text: branch,
                    url: delivery.remote?.branchUrl(branch),
                    style: muted,
                  ),
                ),
              ],
            ),
          if (delivery.lineLabel case final lines?) Text(lines, style: muted),
          if (delivery.isDirty)
            Text('${delivery.dirtyFiles} uncommitted', style: muted),
          if ((delivery.aheadOfBase ?? 0) > 0 && delivery.baseBranch != null)
            Text(
              '${delivery.aheadOfBase} ahead of ${delivery.baseBranch}',
              style: muted,
            ),
          if (pr != null)
            RemoteLink(
              text: '#${pr.number}',
              url: pr.url,
              style: label,
              tooltip: pr.title.isEmpty ? pr.url : pr.title,
              icon: true,
            ),
          if (pr?.checks.label case final checks?)
            Text(
              checks,
              style: label?.copyWith(
                color: pr!.checks.state == ChecksState.failing
                    ? semantic.failure
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

/// One action, primary or not, enabled or not with the reason attached.
class _ActionChip extends StatelessWidget {
  const _ActionChip({required this.offered, required this.onPressed});

  final OfferedAction offered;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final action = offered.action;
    final chip = ActionChip(
      avatar: Icon(_actionIcon(action), size: 14),
      label: Text(action.label),
      backgroundColor: offered.isPrimary && offered.isEnabled
          ? theme.colorScheme.primaryContainer
          : null,
      labelStyle: offered.isPrimary
          ? theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w600,
              color: offered.isEnabled
                  ? theme.colorScheme.onPrimaryContainer
                  : theme.colorScheme.onSurfaceVariant,
            )
          : null,
      onPressed: onPressed,
    );
    return Tooltip(
      message:
          offered.disabledReason ??
          (action.isPrompt
              ? 'Sends “${action.prompt}”'
              : _appActionTooltip(action)),
      child: chip,
    );
  }
}

String _appActionTooltip(DeliveryAction action) => switch (action) {
  DeliveryAction.viewPullRequest => 'Opens the pull request in your browser',
  DeliveryAction.viewChecks => 'Opens the checks in your browser',
  DeliveryAction.archive =>
    'Removes the worktree directory. The transcript, review notes and '
        'checkpoints are kept.',
  _ => '',
};

IconData _actionIcon(DeliveryAction action) => switch (action) {
  DeliveryAction.commit => AppIcons.check,
  DeliveryAction.push => AppIcons.arrowUp,
  DeliveryAction.openPullRequest => AppIcons.gitMerge,
  DeliveryAction.viewPullRequest => AppIcons.arrowSquareOut,
  DeliveryAction.viewChecks => AppIcons.checkCircle,
  DeliveryAction.merge => AppIcons.gitMerge,
  DeliveryAction.runTests => AppIcons.play,
  DeliveryAction.archive => AppIcons.trash,
};

IconData _stageIcon(DeliveryStage stage) => switch (stage) {
  DeliveryStage.working => AppIcons.pencilSimple,
  DeliveryStage.committed => AppIcons.check,
  DeliveryStage.pushed => AppIcons.arrowUp,
  DeliveryStage.prOpen => AppIcons.gitMerge,
  DeliveryStage.checksPassing => AppIcons.checkCircle,
  DeliveryStage.checksFailing => AppIcons.warningCircle,
  DeliveryStage.merged => AppIcons.gitMerge,
  DeliveryStage.archived => AppIcons.folder,
};
