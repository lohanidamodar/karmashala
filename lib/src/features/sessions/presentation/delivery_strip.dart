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
  const DeliveryStrip({
    required this.sessionId,
    this.hostedOnTerminal = false,
    super.key,
  });

  final String sessionId;

  /// Whether the strip is drawn in the session bar under the terminal rather
  /// than above the conversation's composer. One parameter, not a second
  /// widget: it only changes how the strip is dressed.
  ///
  /// The bar is already chrome — it draws the rule above itself and the surface
  /// behind it — so the strip brings neither. It also brings no state line:
  /// under the terminal this is **the actions and nothing else**, and the facts
  /// are drawn above them by [DeliveryStateLine], which the bar hosts itself.
  ///
  /// That reverses a decision worth naming. The two were poured into one [Wrap]
  /// to keep the bar one row deep at ordinary widths, and it did not work out
  /// that way: `deliveryActionsFor` over-offers on purpose (Loop 33), so a live
  /// agent's bar holds four or five actions plus five facts and wraps anyway —
  /// into two *ragged* rows with `Commit` stranded up beside the branch name,
  /// away from the three buttons it belongs with. The row was never saved; only
  /// the grouping was lost. Two rows that mean something ("what is true" over
  /// "what I can do") cost the same and read as structure instead of a spill.
  final bool hostedOnTerminal;

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
    const continueTooltip =
        'Move this session to another agent, or fork it. '
        'Nothing is launched until you have seen what the next '
        'agent will be told.';
    void continueWith() =>
        ContinueWithDialog.show(context, widget.sessionId);

    if (widget.hostedOnTerminal) {
      // The action row, and only the action row. Every button in it is the
      // bar's own pill at the bar's own weight, so the row reads as a row of
      // peers with exactly one of them filled — see [_BarAction].
      return Wrap(
        spacing: Insets.sm,
        runSpacing: Insets.xs,
        children: [
          for (final offered in actions)
            _BarAction(
              icon: _actionIcon(offered.action),
              label: offered.action.label,
              tooltip: _actionTooltip(offered),
              primary: offered.isPrimary,
              onPressed: _busy || !offered.isEnabled
                  ? null
                  : () => _press(offered.action, delivery),
            ),
          if (canContinue)
            _BarAction(
              icon: AppIcons.arrowBendDownRight,
              label: 'Continue with…',
              tooltip: continueTooltip,
              onPressed: _busy ? null : continueWith,
            ),
        ],
      );
    }

    final buttons = [
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
          tooltip: continueTooltip,
          onPressed: _busy ? null : continueWith,
        ),
    ];

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
            children: buttons,
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
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Insets.md, 6, Insets.sm, 0),
    child: Wrap(
      spacing: Insets.sm,
      runSpacing: Insets.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: _deliveryFacts(context, delivery),
    ),
  );
}

/// The same state line, for the session bar under the terminal, read from the
/// session rather than handed a [SessionDelivery].
///
/// **A line of facts, above a row of controls.** Nothing here is pressable and
/// nothing is drawn in a container: the bar says what is true in quiet muted
/// text, and then says what you can do about it in pills. That separation is
/// the whole redesign — set at the same weight and in the same run as the
/// buttons, eight peers read as one undifferentiated spill.
///
/// It is its own widget so the bar can lay the two out itself, and it keeps its
/// own emptiness (a session with nothing known about its delivery draws no line
/// and reserves no room). That is not a second copy of [DeliveryStrip]'s rule:
/// the strip decides whether there are *actions*, this decides whether there
/// are *facts*, and with neither the bar is left with the two controls at its
/// ends, which is what it drew before either of them had anything to say.
class DeliveryStateLine extends ConsumerWidget {
  const DeliveryStateLine({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // `.value` for the reason [DeliveryStrip.build] gives: a refresh must not
    // take the line away and move everything laid out around it.
    final delivery = ref.watch(sessionDeliveryProvider(sessionId)).value;
    if (delivery == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: Insets.xs),
      child: Wrap(
        spacing: Insets.sm,
        runSpacing: Insets.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: _deliveryFacts(context, delivery),
      ),
    );
  }
}

/// What the state line is made of, as separate pieces.
///
/// A list rather than a widget because both hosts wrap them in a [Wrap] of
/// their own: nested, the whole state would break to a run of its own long
/// before it had run out of room.
List<Widget> _deliveryFacts(BuildContext context, SessionDelivery delivery) {
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

  return [
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
  ];
}

/// One action above the conversation's composer: a Material chip, at the scale
/// of the message column it belongs to.
class _ActionChip extends StatelessWidget {
  const _ActionChip({required this.offered, required this.onPressed});

  final OfferedAction offered;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final action = offered.action;
    // The primary action keeps its weight and its container in either host —
    // which of these to press next is the one thing the strip is saying.
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
    return Tooltip(message: _actionTooltip(offered), child: chip);
  }
}

/// The vertical padding every control on the session bar's action row draws
/// with, and the reason they all sit on one line.
///
/// `PermissionModeChip`, [_BarAction] and the view toggle are each a single
/// line of `labelSmall` with this above and below it inside a `Radii.sm`
/// rectangle, so all three are exactly the same height — at 100% text and at
/// 200% — and their centres coincide however the row is aligned. The number is
/// the permission chip's own; that widget belongs to the composer as much as to
/// the bar, so the bar matches it rather than the other way round.
const double kBarControlPad = 3;

/// One action as the session bar draws it: the bar's own pill.
///
/// **One weight, one primary.** The strip used to put a filled Material chip
/// (`Commit`), three outlined ones and a hand-drawn dropdown in a row and leave
/// the eye to work out which mattered — four kinds of control saying four
/// different things about their own importance. Every action is now the same
/// rectangle as the two controls at the ends of the row, and the *only*
/// difference left in the group is the fill on the one action that is the next
/// sensible step. A Material `ActionChip` could not be that shape: it is a
/// stadium sized for a message column, which is what made the actions read as
/// chips that had landed on the wrong surface.
///
/// Disabled is drawn, not hidden — `Merge` with "Checks are failing." on it
/// says both what comes next and why it cannot happen yet — so the reason
/// stays on the tooltip of a pill that is still there.
class _BarAction extends StatelessWidget {
  const _BarAction({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onPressed,
    this.primary = false,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = onPressed != null;
    // The fill is the emphasis, so a primary that cannot be pressed keeps its
    // weight and loses its container rather than pretending to be ready.
    final filled = primary && enabled;
    final foreground = !enabled
        ? scheme.onSurfaceVariant
        : filled
        ? scheme.onPrimaryContainer
        : scheme.onSurface;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: label,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(Radii.sm),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.sm,
              vertical: kBarControlPad,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Radii.sm),
              color: filled ? scheme.primaryContainer : null,
              // The same box either way, so promoting an action moves nothing
              // beside it: the border only changes colour.
              border: Border.all(
                color: filled ? scheme.primaryContainer : scheme.outlineVariant,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: Chrome.iconSmall, color: foreground),
                const SizedBox(width: Insets.xs),
                // Flexible so a pill wider than the room left for it ellipsises
                // instead of overflowing: at 200% text "Archive worktree" is
                // wider than the gap between the permission control and the
                // toggle. The glyph, the tooltip and the semantics label all
                // survive the trim, so nothing is lost but letters.
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: foreground,
                      fontWeight: primary ? FontWeight.w600 : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What a delivery action says on hover: why it cannot be pressed, or what
/// pressing it does. One answer, so the two hosts cannot describe an action
/// differently.
String _actionTooltip(OfferedAction offered) =>
    offered.disabledReason ??
    (offered.action.isPrompt
        ? 'Sends “${offered.action.prompt}”'
        : _appActionTooltip(offered.action));

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
