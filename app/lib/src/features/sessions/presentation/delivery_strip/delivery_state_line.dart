// The delivery state line: stage mark and the facts behind it.

part of '../delivery_strip.dart';

/// The state line: how far the work has got, and the numbers behind that.
class _DeliveryState extends StatelessWidget {
  const _DeliveryState({required this.delivery, required this.sessionId});

  final SessionDelivery delivery;

  /// Carried through only for the verification verdict, which is the one fact
  /// in the line that is not a property of [SessionDelivery].
  final String sessionId;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Insets.md, Insets.xsm, Insets.sm, 0),
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
  const DeliveryStateLine({
    required this.sessionId,
    this.singleLine = false,
    super.key,
  });

  /// One line only, as the phone's bar has: the facts that do not fit are
  /// left out whole, in order, rather than cut at the edge.
  final bool singleLine;

  /// One line's height, the tallest fact's.
  static const double _lineHeight = 24;

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
    final hasModel =
        ref.watch(
          sessionModelProvider(sessionId).select(SessionModelMark.namesAModel),
        ) ||
        ref.watch(
          sessionActiveModelProvider(sessionId).select((a) => a != null),
        );
    // The same for the sessions sharing its checkout.
    final shared = ref.watch(
      sessionCheckoutSharersProvider(sessionId).select((s) => s.isNotEmpty),
    );
    final facts = _deliveryFacts(
      context,
      delivery,
      sessionId,
      withModel: hasModel,
      withSharers: shared,
    );
    if (singleLine) {
      // The stage, first, ends with an ellipsis once it is all that fits.
      return SizedBox(
        height: _lineHeight,
        child: YieldingRow(
          yieldFromStart: false,
          children: [
            for (final (i, fact) in facts.indexed)
              Padding(
                padding: EdgeInsets.only(left: i == 0 ? 0 : Insets.sm),
                child: fact,
              ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: Insets.xxs, bottom: Insets.xs),
      child: Wrap(
        spacing: Insets.sm,
        runSpacing: Insets.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: facts,
      ),
    );
  }
}

/// The stage's icon and word. `working` is the git stage "nothing recorded
/// yet", which read as the agent working whenever the agent was not.
class _StageMark extends ConsumerWidget {
  const _StageMark({
    required this.sessionId,
    required this.delivery,
    required this.colour,
    required this.style,
  });

  final String sessionId;
  final SessionDelivery delivery;
  final Color colour;
  final TextStyle? style;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watchSession(sessionId);
    final stage = delivery.stage;
    final row = ref.read(sessionsDataProvider).getById(sessionId);
    // Judged by what runs it, not by the row's word: after a restart a row
    // can still say running, or unknown, with nothing behind it.
    final runs =
        ref.watch(
          sessionWhereaboutsProvider(sessionId).select((w) => w.hostedLive),
        ) ||
        ref.read(sessionRunningOnHostProvider)(sessionId) ||
        (row != null &&
            row.status.claimsLive &&
            ref.watch(isAcpSessionProvider(sessionId)));
    // Relaunched to take a message: its pane is not up yet, but it is coming.
    final starting =
        stage == DeliveryStage.working &&
        !runs &&
        ref.watch(
          sessionsStartingProvider.select((ids) => ids.contains(sessionId)),
        );
    final stopped =
        stage == DeliveryStage.working && row != null && !runs && !starting;
    final agentWorking = ref.watch(
      agentSessionStatusProvider(
        sessionId,
      ).select((report) => report.value?.status == AgentActivityStatus.working),
    );
    // The uncommitted count is its own fact beside this one.
    final word = switch (stage) {
      _ when starting => 'Starting',
      _ when stopped => 'Not running',
      DeliveryStage.working when !agentWorking =>
        delivery.isDirty ? 'Uncommitted' : 'No changes yet',
      _ => stage.label,
    };
    // Ends rather than overflows a line the chips beside it have narrowed.
    final text = Text(
      word,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: style?.copyWith(color: colour),
    );
    return LayoutBuilder(
      key: const ValueKey('delivery-stage'),
      // Narrower than the icon, as the phone bar's badges can leave it: the
      // word alone, so the icon is the clause that gives way.
      builder: (context, constraints) =>
          constraints.maxWidth < Chrome.iconSmall + Insets.xs
          ? text
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  stopped ? AppIcons.stopCircle : _stageIcon(stage),
                  size: Chrome.iconSmall,
                  color: colour,
                ),
                const SizedBox(width: Insets.xs),
                Flexible(child: text),
              ],
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
  bool withSharers = false,
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
    _StageMark(
      sessionId: sessionId,
      delivery: delivery,
      colour: colour,
      style: label,
    ),
    // Beside the stage: how far the work got, and whether anything checked it.
    // Nothing when nothing ever did (SessionVerdictMark).
    SessionVerdictMark(sessionId: sessionId),
    // Other live sessions writing in the same checkout, named on hover.
    if (withSharers) SharedCheckoutBadge(sessionId: sessionId),
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
          // Ends in a line narrower than the name, as on one status line.
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: RemoteLink(
                text: branch,
                url: delivery.remote?.branchUrl(branch),
                style: muted,
              ),
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
