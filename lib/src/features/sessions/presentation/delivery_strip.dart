import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../agents/application/session_model_providers.dart';
import 'package:agent_cli/process.dart';
import '../../explorer/application/checkout.dart';
import '../../git/application/remote_links.dart';
import '../../github/application/github_providers.dart';
import '../../git/presentation/remote_link.dart';
import 'package:karmashala_git/github.dart';
import '../../repositories/application/repository_providers.dart';
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
import '../domain/delivery_action.dart';
import '../domain/delivery_stage.dart';
import '../domain/session_delivery.dart';
import 'continue_with_dialog.dart';
import 'model_chip.dart';

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
/// opening the pull request or its checks hands a URL to the browser, updating
/// from the base branch and taking a pull request out of draft are single
/// operations with nothing to compose, and archiving the worktree is a
/// destructive local operation that asks first. All of them report what they
/// did in a snackbar, because they have no transcript to report into — that is
/// the price of owning an action rather than delegating it, and it is why the
/// strip owns as few as it can.
class DeliveryStrip extends ConsumerStatefulWidget {
  const DeliveryStrip({
    required this.sessionId,
    this.hostedOnTerminal = false,
    this.compact = false,
    super.key,
  });

  final String sessionId;

  /// Icon-only pills, for a workspace group too narrow to spell the verbs.
  ///
  /// The labels are what a narrow bar gives up, and the buttons are what it
  /// keeps: `deliveryActionsFor` over-offers on purpose, so five labelled pills
  /// are ~440px and five glyphs are ~150. The tooltip and the semantics label
  /// are unchanged, so a pointer and a screen reader both still get the word —
  /// only the letters go. Hiding an action behind an overflow menu instead
  /// would put `Commit`, the one thing most visits to this bar are for, two
  /// clicks away.
  final bool compact;

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

  /// Sends [offered]'s sentence, which is not always its action's own: `Merge`
  /// names the strategy the repository allows. Reading it off [OfferedAction]
  /// rather than off [DeliveryAction] is what keeps the sentence sent and the
  /// sentence shown on the tooltip identical.
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

  /// Merges the base branch in, and re-reads everything afterwards.
  ///
  /// No confirmation. Unlike archiving, every outcome of this is recoverable —
  /// the worst case is a merge commit and `git reset --hard HEAD^` — and the
  /// service refuses outright in exactly the situations where it would not be
  /// (a live agent, an uncommitted edit, a conflict). A dialog in front of an
  /// operation that cannot destroy anything trains people to dismiss dialogs.
  Future<void> _update() => _run(() async {
    final messenger = ScaffoldMessenger.of(context);
    final outcome = await ref
        .read(deliveryUpdateServiceProvider)
        .updateFromBase(widget.sessionId);
    if (outcome.isUpdated) _reread();
    messenger.showSnackBar(SnackBar(content: Text(outcome.message)));
  });

  /// Takes the pull request out of draft.
  ///
  /// Inline rather than behind a service of its own: there is no precondition
  /// to check that the offer did not already check, no local state to protect,
  /// and one failure mode — `gh` said no — which is reported exactly as `gh`
  /// worded it. A service wrapping a single command with no rules in it would
  /// be a file to keep in step for nothing.
  Future<void> _markReady(SessionDelivery? delivery) => _run(() async {
    final messenger = ScaffoldMessenger.of(context);
    final number = delivery?.pullRequest?.number;
    final directory = _directory();
    if (number == null || directory == null) return;
    try {
      await ref
          .read(gitHubReviewServiceProvider)
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
    final session = ref.read(sessionDaoProvider).getById(widget.sessionId);
    if (session == null) return null;
    return session.worktree ??
        ref.read(repositoryDaoProvider).getById(session.repositoryId)?.path;
  }

  /// Re-reads the delivery state after one of the app's own writes.
  ///
  /// The poll is two minutes wide and neither of these writes goes through the
  /// session-revision signal the local provider watches, so without this the
  /// strip would keep offering `Update` on a branch that is no longer behind
  /// for up to two minutes — which reads as the button having done nothing.
  /// Both keys are invalidated because the two halves answer different
  /// questions and either write can move either half: an update moves the
  /// local counts, and `gh pr ready` moves the pull request.
  void _reread() {
    final directory = _directory();
    if (directory == null) return;
    ref.invalidate(checkoutDeliveryProvider(Checkout(directory)));
    ref.invalidate(checkoutPullRequestProvider(Checkout(directory)));
  }

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
        '$kContinueWithPromise';
    void continueWith() => ContinueWithDialog.show(context, widget.sessionId);

    // In the row of controls, not in the line of facts: "facts above, controls
    // below" is this strip's redesign, and a pressable thing among the stage
    // and the branch would undo it. Directly under the verdict is as beside it
    // as that separation allows.
    final invitation = ReviewInvitation.forVerdict(
      ref.watch(sessionVerdictProvider(widget.sessionId)).state,
    );
    // Hidden rather than disabled when nobody can be asked, matching the
    // follow-up row: this strip is on *every* session, so a dead control here
    // reads as a broken feature rather than as a machine with one agent on it.
    // The refusal keeps its home on [ReviewAction]'s own button, where the
    // control is the surface's subject. Short-circuited because the answer
    // costs three row lookups a rebuild.
    final review =
        invitation != null &&
            ref.watch(sessionReviewOfferProvider(widget.sessionId)).isPossible
        ? invitation
        : null;

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
///
/// This host, and only this one, also carries the session's model — see
/// [SessionModelMark] for what that mark does and does not claim. The strip
/// above the composer does not: the same session's model is a chip in the chip
/// row a few pixels below it there, and a second reading of it in the line
/// above would be exactly the duplication this line was pulled out to avoid.
/// The session bar's own chip is not that neighbour, because it is dropped
/// whenever the bar is under ~820px — which is where "what is this thinking
/// with" was hardest to answer.
class DeliveryStateLine extends ConsumerWidget {
  const DeliveryStateLine({required this.sessionId, super.key});

  /// Builds of the line, counted so a cost test can prove that a model change
  /// repaints the mark *inside* it and not the line around it — the whole
  /// point of selecting a bool here and leaving the name to the mark.
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
    // Whether there is a model to name, and nothing more. The name itself is
    // the mark's own subscription, so a model change repaints the mark and not
    // this line; selected down to a bool, this moves at most twice in a
    // session's life. It is asked here rather than left to the mark because a
    // mark that drew nothing would still take a `spacing` on each side of
    // itself and leave a double gap where the model was not — and a session
    // with no model named is the ordinary case, not the rare one.
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

/// What the state line is made of, as separate pieces.
///
/// A list rather than a widget because both hosts wrap them in a [Wrap] of
/// their own: nested, the whole state would break to a run of its own long
/// before it had run out of room.
///
/// [withModel] is the one thing the two hosts disagree about, and it is passed
/// rather than decided here because the answer is about the *host*: only the
/// session bar has no model of its own within reach. See [DeliveryStateLine].
/// The caller has already established there is a model worth a mark — a mark
/// that drew nothing would still cost the run two gaps.
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
        const SizedBox(width: 4),
        Text(stage.label, style: label?.copyWith(color: colour)),
      ],
    ),
    // Beside the stage, because the two answer the neighbouring halves of the
    // same question: how far the work got, and whether anything checked it.
    // It draws in every state — "no check recorded" included — since a fact
    // that vanishes when the answer is "nothing" reads as a clean bill of
    // health to anyone scanning the line.
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
    // After the branch, because the two are the neighbouring halves of "where
    // is this work and what is doing it", and because the line's existing scan
    // order — how far, whether it was checked, where it lives — is the one
    // people already read.
    if (withModel) SessionModelMark(sessionId: sessionId),
    if (delivery.lineLabel case final lines?) Text(lines, style: muted),
    if (delivery.isDirty)
      Text('${delivery.dirtyFiles} uncommitted', style: muted),
    if ((delivery.aheadOfBase ?? 0) > 0 && delivery.baseBranch != null)
      Text(
        '${delivery.aheadOfBase} ahead of ${delivery.baseBranch}',
        style: muted,
      ),
    // Beside "ahead", because they are the two halves of one answer and a line
    // that says only how far ahead a branch is reads as "up to date" to anyone
    // scanning it. Drawn in the attention colour rather than muted: unlike the
    // counts around it, this one is a thing to do something about.
    //
    // The count is omitted when it is zero, because that is the case where
    // GitHub told us the branch is behind and the local ref has not been
    // fetched since — "behind main" with no number is exactly as much as is
    // known, and printing "0 behind main" would be a contradiction.
    if (delivery.isBehindBase && delivery.baseBranch != null)
      Text(
        (delivery.behindBase ?? 0) > 0
            ? '${delivery.behindBase} behind ${delivery.baseBranch}'
            : 'behind ${delivery.baseBranch}',
        style: label?.copyWith(color: semantic.attention),
      ),
    // A fact, not a button: `Resolve conflicts` is already the primary action
    // in this state, and the line's job is to say what is true so the row of
    // controls below does not have to carry the explanation on a tooltip.
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
                if (!compact) ...[
                  const SizedBox(width: Insets.xs),
                  // Flexible so a pill wider than the room left for it
                  // ellipsises instead of overflowing: at 200% text "Archive
                  // worktree" is wider than the gap between the permission
                  // control and the toggle. The glyph, the tooltip and the
                  // semantics label all survive the trim, so nothing is lost
                  // but letters.
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
/// pressing it does. One answer, so the two hosts cannot describe an action
/// differently.
String _actionTooltip(OfferedAction offered) {
  final reason = offered.disabledReason;
  if (reason != null) return reason;
  final prompt = offered.prompt;
  return prompt == null
      ? _appActionTooltip(offered.action)
      : 'Sends “$prompt”';
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
