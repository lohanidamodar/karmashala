import '../../workspaces/data/workspace_data.dart';
import '../../../app/widgets/yielding_row.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../agents/application/session_model_providers.dart';
import '../../automations/application/automation_check_runner.dart';
import 'package:agent_cli/descriptors.dart' show AgentActivityStatus;
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
import 'archive_session_action.dart';
import '../application/session_handoff_service.dart';
import '../application/acp_session_providers.dart';
import '../application/session_active_model_providers.dart';
import '../application/host_lifecycle/host_lifecycle_providers.dart';
import '../application/session_providers.dart';
import '../application/session_resume_providers.dart';
import '../application/session_signals.dart';
import '../application/session_status_providers.dart';
import '../application/session_ui_providers.dart' show sessionsStartingProvider;
import 'package:karmashala_session/delivery.dart';
import 'continue_with_dialog.dart';
import 'model_chip.dart';

part 'delivery_strip/delivery_state_line.dart';
part 'delivery_strip/delivery_actions.dart';

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

  Future<void> _archive() =>
      _run(() => deleteSessionWorktree(context, ref, widget.sessionId));

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
    // A first check is not offered on the bar: a verification nobody runs
    // was a fact and a button on every session (owner, 2026-10-07). It
    // stays in the Verification pane; a check that has run is still offered
    // again here.
    final offered = ReviewInvitation.forVerdict(
      ref.watch(sessionVerdictProvider(widget.sessionId)).state,
    );
    final invitation = offered == ReviewInvitation.check ? null : offered;
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
