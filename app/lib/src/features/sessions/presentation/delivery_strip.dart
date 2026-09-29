import '../../workspaces/data/workspace_data.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/dialogs.dart';
import '../../agents/application/session_model_providers.dart';
import '../../automations/application/automation_check_runner.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_git/repositories.dart';
import '../../git/application/remote_links.dart';
import '../../git/data/git_data.dart';
import '../../github/presentation/pull_request_context_dialog.dart';
import '../../git/presentation/remote_link.dart';
import 'package:karmashala_git/github.dart';
import '../../verification/application/review_session_service.dart';
import '../../verification/application/verification_providers.dart';
import '../../verification/presentation/review_action.dart';
import '../../verification/presentation/review_invitation.dart';
import '../../verification/presentation/session_verdict_mark.dart';
import '../application/delivery_providers.dart';
import '../application/session_actions.dart';
import '../application/delivery_update_service.dart';
import '../application/session_archive_service.dart';
import '../application/session_handoff_service.dart';
import '../application/session_providers.dart';
import 'package:karmashala_session/delivery.dart';
import 'continue_with_dialog.dart';
import 'model_chip.dart';

/// One strip, above the message box, carrying a session's whole delivery
/// lifecycle. The agent's steps are **prompts**; what the app owns, it reports.
class DeliveryStrip extends ConsumerStatefulWidget {
  const DeliveryStrip({
    required this.sessionId,
    this.hostedOnTerminal = false,
    this.compact = false,
    this.folded = false,
    super.key,
  });

  final String sessionId;

  /// Icon-only pills, for a workspace group too narrow to spell the verbs. Five
  /// labelled are ~440px against ~150; tooltip and semantics label survive.
  final bool compact;

  /// On the pane's one status line: the primary action as the one filled
  /// pill, everything else behind **Ship ▾**. Only with [hostedOnTerminal].
  final bool folded;

  /// Whether the strip is drawn in the session bar under the terminal. The bar
  /// is already chrome, so no rule, no surface, no [DeliveryStateLine].
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

  /// Sends [offered]'s sentence, which is not always its action's own: `Merge`
  /// names the strategy the repository allows, and the tooltip shows the same.
  Future<void> _send(OfferedAction offered) => _run(() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(sessionActionsProvider)
          .continueSession(widget.sessionId, offered.prompt!);
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

  /// Merges the base branch in, and re-reads afterwards. No confirmation: every
  /// outcome is recoverable, and a needless dialog teaches dismissal.
  Future<void> _update() => _run(() async {
    final messenger = ScaffoldMessenger.of(context);
    final outcome = await ref
        .read(deliveryUpdateServiceProvider)
        .updateFromBase(widget.sessionId);
    if (outcome.isUpdated) _reread();
    messenger.showSnackBar(SnackBar(content: Text(outcome.message)));
  });

  /// Takes the pull request out of draft. Inline rather than behind a service:
  /// one failure mode, `gh` said no, reported exactly as `gh` worded it.
  Future<void> _markReady(SessionDelivery? delivery) => _run(() async {
    final messenger = ScaffoldMessenger.of(context);
    final number = delivery?.pullRequest?.number;
    final directory = _directory();
    if (number == null || directory == null) return;
    try {
      await ref
          .read(gitDataProvider)
          .markPullRequestReady(directory, number: number);
      _reread();
      messenger.showSnackBar(
        SnackBar(content: Text('Pull request #$number is ready for review.')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  });

  /// Where this session's git lives — its worktree, or the repository itself.
  EnvironmentPath? _directory() {
    final session = ref.read(sessionsDataProvider).getById(widget.sessionId);
    if (session == null) return null;
    return session.worktree ??
        ref.read(workspaceDataProvider).repository(session.repositoryId)?.path;
  }

  /// Re-reads the delivery state after one of the app's own writes: neither
  /// goes through the session-revision signal the two-minute poll watches.
  void _reread() {
    final directory = _directory();
    if (directory == null) return;
    ref.invalidate(checkoutDeliveryProvider(Checkout(directory)));
    ref.invalidate(checkoutForgeProvider(Checkout(directory)));
  }

  Future<void> _archive() => _run(() async {
    final messenger = ScaffoldMessenger.of(context);
    final worktree = ref
        .read(sessionsDataProvider)
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
      // A second, separate confirmation: this one destroys work no branch
      // holds, and it is asked about *this* session rather than set as a mode.
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
          if (destructive)
            DestructiveButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(action),
            )
          else
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(action),
            ),
        ],
      ),
    );
  }

  void _press(OfferedAction offered, SessionDelivery? delivery) {
    final pr = delivery?.pullRequest;
    switch (offered.action) {
      case DeliveryAction.viewPullRequest:
        _open(pr?.url);
      case DeliveryAction.viewChecks:
        _open(pr?.url == null ? null : '${pr!.url}/checks');
      case DeliveryAction.updateFromBase:
        _update();
      case DeliveryAction.markReady:
        _markReady(delivery);
      case DeliveryAction.archive:
        _archive();
      default:
        _send(offered);
    }
  }

  @override
  Widget build(BuildContext context) {
    // `.value` keeps the previous answer through a refresh: reading it as null
    // lost the state line and collapsed the strip from 131px to 57px.
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
        '$kContinueWithPromise';
    void continueWith() => ContinueWithDialog.show(context, widget.sessionId);
    // Attaching the pull request the strip is already showing: the facts are
    // here, so the way to hand them to the agent belongs here too.
    void attachContext() => unawaited(
      PullRequestContextDialog.show(context, ref, widget.sessionId),
    );
    const attachTooltip =
        'Attach this pull request — its branches, conflicts, failing checks and '
        'open review conversations — to the session. You see the exact text '
        'before it is sent, and it is kept so you can read it back.';

    // In the row of controls, not in the line of facts: "facts above, controls
    // below" is this strip's redesign, and a pressable fact would undo it.
    final invitation = ReviewInvitation.forVerdict(
      ref.watch(sessionVerdictProvider(widget.sessionId)).state,
    );
    // Hidden rather than disabled when nobody can be asked: this strip is on
    // *every* session, so a dead control reads as a broken feature.
    final review =
        invitation != null &&
            ref.watch(sessionReviewOfferProvider(widget.sessionId)).isPossible
        ? invitation
        : null;

    // The repository's own checks, run by the app and recorded against this
    // session — the evidence the verdict mark in the line above then shows.
    final hasChecks = ref.watch(
      sessionHasProjectChecksProvider(widget.sessionId),
    );
    final checking = ref.watch(
      runningSessionChecksProvider.select((s) => s.contains(widget.sessionId)),
    );
    const checksTooltip =
        'Run this repository\'s project checks in sessions Karmashala owns, in '
        'the directory this session works in. The result is recorded against the '
        'session as Karmashala\'s own reading and shown beside the stage.';
    void runChecks() => unawaited(
      ref.read(runningSessionChecksProvider.notifier).run(widget.sessionId),
    );

    if (widget.hostedOnTerminal && widget.folded) {
      final primary = actions.where((a) => a.isPrimary).firstOrNull;
      List<_ShipEntry> entries(ReviewActionPresentation? offer) => [
        for (final offered in actions)
          if (!identical(offered, primary))
            _ShipEntry(
              icon: _actionIcon(offered.action),
              label: offered.action.askLabel,
              onPressed: _busy || !offered.isEnabled
                  ? null
                  : () => _press(offered, delivery),
            ),
        if (review != null && offer != null)
          _ShipEntry(
            icon: AppIcons.listMagnifyingGlass,
            label: review.label,
            onPressed: _busy ? null : offer.onPressed,
          ),
        if (hasChecks)
          _ShipEntry(
            icon: AppIcons.listChecks,
            label: checking ? 'Checking…' : 'Run checks',
            onPressed: _busy || checking ? null : runChecks,
          ),
        if (delivery?.pullRequest != null)
          _ShipEntry(
            icon: AppIcons.gitMerge,
            label: 'Attach PR…',
            onPressed: _busy ? null : attachContext,
          ),
        if (canContinue)
          _ShipEntry(
            icon: AppIcons.arrowBendDownRight,
            label: 'Continue with…',
            onPressed: _busy ? null : continueWith,
          ),
      ];
      Widget ship(ReviewActionPresentation? offer) {
        final all = entries(offer);
        return all.isEmpty ? const SizedBox.shrink() : _ShipMenu(entries: all);
      }

      final next = primary == null
          ? null
          : _BarAction(
              icon: _actionIcon(primary.action),
              label: primary.action.label,
              tooltip: _actionTooltip(primary),
              primary: true,
              compact: widget.compact,
              onPressed: _busy || !primary.isEnabled
                  ? null
                  : () => _press(primary, delivery),
            );
      // The next step's label ends before the row overflows — where the row
      // has an edge. In a scrolling row it has none, and keeps its words.
      return LayoutBuilder(
        builder: (context, box) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (next != null) ...[
              if (box.hasBoundedWidth) Flexible(child: next) else next,
              const SizedBox(width: Insets.xs),
            ],
            // The review offer is decided inside [ReviewAction]; the menu only
            // borrows what it says and does.
            if (review != null)
              ReviewAction(
                sessionId: widget.sessionId,
                builder: (context, offer) => ship(offer),
              )
            else
              ship(null),
          ],
        ),
      );
    }

    if (widget.hostedOnTerminal) {
      // The action row, and only the action row: every button is the bar's own
      // pill at the bar's own weight, with exactly one of them filled.
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
              compact: widget.compact,
              onPressed: _busy || !offered.isEnabled
                  ? null
                  : () => _press(offered, delivery),
            ),
          if (review != null)
            ReviewAction(
              sessionId: widget.sessionId,
              builder: (context, offer) => _BarAction(
                icon: AppIcons.listMagnifyingGlass,
                label: review.label,
                tooltip: offer.tooltip,
                onPressed: _busy ? null : offer.onPressed,
              ),
            ),
          if (hasChecks)
            _BarAction(
              icon: AppIcons.listChecks,
              label: checking ? 'Checking…' : 'Run checks',
              tooltip: checksTooltip,
              compact: widget.compact,
              onPressed: _busy || checking ? null : runChecks,
            ),
          if (delivery?.pullRequest != null)
            _BarAction(
              icon: AppIcons.gitMerge,
              label: 'Attach PR…',
              tooltip: attachTooltip,
              compact: widget.compact,
              onPressed: _busy ? null : attachContext,
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
              : () => _press(offered, delivery),
        ),
      if (review != null)
        ReviewAction(
          sessionId: widget.sessionId,
          builder: (context, offer) => ActionChip(
            avatar: const Icon(
              AppIcons.listMagnifyingGlass,
              size: Chrome.iconAction,
            ),
            label: Text(review.label),
            tooltip: offer.tooltip,
            onPressed: _busy ? null : offer.onPressed,
          ),
        ),
      if (hasChecks)
        ActionChip(
          avatar: const Icon(AppIcons.listChecks, size: Chrome.iconAction),
          label: Text(checking ? 'Checking…' : 'Run checks'),
          tooltip: checksTooltip,
          onPressed: _busy || checking ? null : runChecks,
        ),
      if (delivery?.pullRequest != null)
        ActionChip(
          avatar: const Icon(AppIcons.gitMerge, size: Chrome.iconAction),
          label: const Text('Attach PR…'),
          tooltip: attachTooltip,
          onPressed: _busy ? null : attachContext,
        ),
      if (canContinue)
        ActionChip(
          avatar: const Icon(
            AppIcons.arrowBendDownRight,
            size: Chrome.iconAction,
          ),
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
        if (delivery != null)
          _DeliveryState(delivery: delivery, sessionId: widget.sessionId),
        Padding(
          // Padded on all four sides: the strip is hosted under the terminal as
          // well as above the composer, and there nothing below gives it room.
          padding: const EdgeInsets.fromLTRB(
            Insets.sm,
            Insets.xs,
            Insets.sm,
            Insets.xs,
          ),
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
  const _DeliveryState({required this.delivery, required this.sessionId});

  final SessionDelivery delivery;

  /// Carried through only for the verification verdict, which is the one fact
  /// in the line that is not a property of [SessionDelivery].
  final String sessionId;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Insets.md, 6, Insets.sm, 0),
    child: Wrap(
      spacing: Insets.sm,
      runSpacing: Insets.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: _deliveryFacts(context, delivery, sessionId),
    ),
  );
}

/// The same state line, for the session bar under the terminal. **Facts above,
/// controls below**: at the buttons' weight, eight peers read as one spill.
class DeliveryStateLine extends ConsumerWidget {
  const DeliveryStateLine({required this.sessionId, super.key});

  /// Builds of the line, counted so a cost test can prove that a model change
  /// repaints the mark *inside* it and not the line around it.
  @visibleForTesting
  static int debugBuildCount = 0;

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    DeliveryStateLine.debugBuildCount++;
    // `.value` for the reason [DeliveryStrip.build] gives: a refresh must not
    // take the line away and move everything laid out around it.
    final delivery = ref.watch(sessionDeliveryProvider(sessionId)).value;
    if (delivery == null) return const SizedBox.shrink();
    // Whether there is a model to name, and nothing more — the name is the
    // mark's own subscription. A mark that drew nothing would still take gaps.
    final hasModel = ref.watch(
      sessionModelProvider(sessionId).select(SessionModelMark.namesAModel),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: Insets.xs),
      child: Wrap(
        spacing: Insets.sm,
        runSpacing: Insets.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: _deliveryFacts(
          context,
          delivery,
          sessionId,
          withModel: hasModel,
        ),
      ),
    );
  }
}

/// What the state line is made of, as separate pieces — a list, because both
/// hosts wrap them in a [Wrap] of their own. [withModel] is about the *host*.
List<Widget> _deliveryFacts(
  BuildContext context,
  SessionDelivery delivery,
  String sessionId, {
  bool withModel = false,
}) {
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
        Icon(_stageIcon(stage), size: Chrome.iconSmall, color: colour),
        const SizedBox(width: Insets.xs),
        Text(stage.label, style: label?.copyWith(color: colour)),
      ],
    ),
    // Beside the stage: how far the work got, and whether anything checked it.
    // Drawn in every state — a fact that vanishes reads as a clean bill.
    SessionVerdictMark(sessionId: sessionId),
    if (delivery.branch case final branch?)
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            AppIcons.gitBranch,
            size: Chrome.iconSmall,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: Insets.xs),
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
    // After the branch: the two are the halves of "where is this work and what
    // is doing it", and the line's existing scan order is the one people read.
    if (withModel) SessionModelMark(sessionId: sessionId),
    if (delivery.lineLabel case final lines?) Text(lines, style: muted),
    if (delivery.isDirty)
      Text('${delivery.dirtyFiles} uncommitted', style: muted),
    if ((delivery.aheadOfBase ?? 0) > 0 && delivery.baseBranch != null)
      Text(
        '${delivery.aheadOfBase} ahead of ${delivery.baseBranch}',
        style: muted,
      ),
    // Beside "ahead", because how far ahead alone reads as "up to date". The
    // count is omitted when zero — "0 behind main" would be a contradiction.
    if (delivery.isBehindBase && delivery.baseBranch != null)
      Text(
        (delivery.behindBase ?? 0) > 0
            ? '${delivery.behindBase} behind ${delivery.baseBranch}'
            : 'behind ${delivery.baseBranch}',
        style: label?.copyWith(color: semantic.attention),
      ),
    // A fact, not a button: `Resolve conflicts` is already the primary action
    // in this state, so the controls below need not carry the explanation.
    if (delivery.hasConflict)
      Text('conflicts', style: label?.copyWith(color: semantic.failure)),
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
      avatar: Icon(_actionIcon(action), size: Chrome.iconAction),
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

/// One verb behind **Ship ▾**; a null [onPressed] is drawn disabled.
class _ShipEntry {
  const _ShipEntry({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
}

/// **Ship ▾**: the delivery verbs that are not the next one, in one menu.
class _ShipMenu extends StatelessWidget {
  const _ShipMenu({required this.entries});

  final List<_ShipEntry> entries;

  @override
  Widget build(BuildContext context) => Builder(
    builder: (anchor) => _BarAction(
      icon: AppIcons.rocketLaunch,
      label: 'Ship ▾',
      tooltip: 'Review, checks, pull request and handing the session on',
      onPressed: () async {
        final picked = await showDesktopMenuUnder<int>(anchor, [
          for (final (index, entry) in entries.indexed)
            DesktopMenuItem(
              value: index,
              label: entry.label,
              icon: entry.icon,
              enabled: entry.onPressed != null,
            ),
        ]);
        if (picked != null) entries[picked].onPressed?.call();
      },
    ),
  );
}

/// The vertical padding every control on the session bar's action row draws
/// with, so all three are the same height at 100% text and at 200%.
const double kBarControlPad = 3;

/// One action as the session bar draws it: the bar's own pill. **One weight,
/// one primary**, and disabled is drawn rather than hidden.
class _BarAction extends StatelessWidget {
  const _BarAction({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onPressed,
    this.primary = false,
    this.compact = false,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool primary;

  /// Glyph only — see [DeliveryStrip.compact].
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = onPressed != null;
    // The mockup's pill: a hairline and no fill. The primary is the accent's
    // ink, not a container — a filled button in a 30px status line shouted
    // over the pane. One that cannot be pressed keeps its weight only.
    final accent = primary && enabled;
    final foreground = !enabled
        ? scheme.onSurfaceVariant
        : accent
        ? scheme.primary
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
              // The same box either way, so promoting an action moves nothing
              // beside it.
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: Chrome.iconSmall, color: foreground),
                if (!compact) ...[
                  const SizedBox(width: Insets.xs),
                  // Flexible so a pill wider than the room left ellipsises: at
                  // 200% text "Archive worktree" is wider than the gap.
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What a delivery action says on hover: why it cannot be pressed, or what
/// pressing it does. One answer, so the two hosts cannot disagree.
String _actionTooltip(OfferedAction offered) {
  final reason = offered.disabledReason;
  if (reason != null) return reason;
  final prompt = offered.prompt;
  return prompt == null
      ? _appActionTooltip(offered.action)
      : 'Asks the agent: “$prompt”';
}

String _appActionTooltip(DeliveryAction action) => switch (action) {
  DeliveryAction.viewPullRequest => 'Opens the pull request in your browser',
  DeliveryAction.viewChecks => 'Opens the checks in your browser',
  DeliveryAction.updateFromBase =>
    'Merges the base branch into this one. Refuses if the tree is dirty, an '
        'agent is running, or the merge would conflict.',
  DeliveryAction.markReady => 'Takes the pull request out of draft',
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
  DeliveryAction.resolveConflicts => AppIcons.warningCircle,
  DeliveryAction.updateFromBase => AppIcons.arrowsClockwise,
  DeliveryAction.addressRequestedChanges => AppIcons.listMagnifyingGlass,
  DeliveryAction.resolveReviewComments => AppIcons.listMagnifyingGlass,
  DeliveryAction.markReady => AppIcons.arrowSquareOut,
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
