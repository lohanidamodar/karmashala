// The peek's status strip and the facts on it.
part of '../overview_peek.dart';

/// **The session's status strip in the peek** — the one place for its facts
/// (owner, 2026-10-08): the state and the model first and never folded, then
/// the permission, where it runs, the operator grant, the usage and the next
/// delivery step. The pickers are the bar's own widgets, not copies, so what
/// is set here is what the session's tab shows. What does not fit folds into
/// +N, which opens the session's [SessionFactList].
///
/// The agent is not on it while the composer can switch it: that picker is
/// the one place the agent is set. [card] is null outside a dashboard.
class OverviewPeekControls extends ConsumerWidget {
  const OverviewPeekControls({required this.sessionId, this.card, super.key});

  final String sessionId;
  final OverviewCard? card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final card = this.card;
    final native = card == null || card.entry.native != null;
    return Container(
      key: const ValueKey('overview-peek-controls'),
      padding: const EdgeInsetsDirectional.only(start: Insets.sm),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
      child: StatusStrip(
        sheetTitle: 'Session',
        sheet: (_) => SessionFactList(sessionId: sessionId, card: card),
        pinned: [
          if (card != null)
            StatusStripItem(
              id: 'state',
              builder: (_, _) => OverviewStatePill(card: card),
            ),
          StatusStripItem(
            id: 'model',
            builder: (_, short) => SessionModelValue(
              sessionId: sessionId,
              short: short,
              native: native,
              bare: false,
            ),
          ),
        ],
        items: [
          if (native) ...[
            StatusStripItem(
              id: 'permission',
              builder: (_, short) =>
                  PermissionModeChip(sessionId: sessionId, short: short),
            ),
            StatusStripItem(
              id: 'mode',
              builder: (_, _) =>
                  SessionModePicker(sessionId: sessionId, leadingGap: false),
            ),
          ],
          StatusStripItem(
            id: 'agent',
            builder: (_, _) => _PeekAgentFact(sessionId: sessionId, card: card),
          ),
          if (card != null) ...[
            StatusStripItem(
              id: 'branch',
              builder: (_, _) => _PeekBranchFact(card: card),
            ),
            StatusStripItem(
              id: 'place',
              builder: (_, _) => _PeekPlaceFact(card: card),
            ),
          ] else
            StatusStripItem(
              id: 'place',
              builder: (_, _) => SessionEnvironmentMark(sessionId: sessionId),
            ),
          if (native)
            StatusStripItem(
              id: 'operator',
              builder: (_, _) =>
                  OperatorChip(sessionId: sessionId, onlyWhenOn: true),
            ),
          if (card != null)
            StatusStripItem(
              id: 'usage',
              builder: (_, _) => OverviewUsageLine(sessionId: sessionId),
            ),
          if (native)
            StatusStripItem(
              id: 'delivery',
              builder: (_, short) => DeliveryStrip(
                sessionId: sessionId,
                hostedOnTerminal: true,
                compact: short,
                folded: true,
              ),
            ),
        ],
        more: native ? SessionMoreButton(sessionId: sessionId) : null,
      ),
    );
  }
}

/// The agent, by name, while nothing else on screen names it.
class _PeekAgentFact extends ConsumerWidget {
  const _PeekAgentFact({required this.sessionId, required this.card});

  final String sessionId;
  final OverviewCard? card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agentId = watchSessionAgentShown(ref, sessionId, card);
    if (agentId == null) return const SizedBox.shrink();
    final name = ref.watch(agentRegistryProvider).displayNameFor(agentId);
    return SessionStripFact(
      key: const ValueKey('overview-peek-agent'),
      icon: AppIcons.robot,
      leading: AgentLogo(agentId: agentId, size: Chrome.iconSmall),
      label: name,
      tooltip: 'Agent: $name',
    );
  }
}

/// The branch its checkout is on, once a reading has named it.
class _PeekBranchFact extends ConsumerWidget {
  const _PeekBranchFact({required this.card});

  final OverviewCard card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final directory = card.entry.directory;
    final branch = directory == null
        ? null
        : ref.watch(overviewKnownBranchProvider(directory));
    if (branch == null) return const SizedBox.shrink();
    return SessionStripFact(
      key: const ValueKey('overview-peek-branch'),
      icon: AppIcons.gitBranch,
      label: branch,
      tooltip: 'Branch: $branch',
    );
  }
}

/// "karmashala · Windows": the project and the machine it runs on.
class _PeekPlaceFact extends ConsumerWidget {
  const _PeekPlaceFact({required this.card});

  final OverviewCard card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final place = watchOverviewPlace(ref, card);
    if (place.isEmpty) return const SizedBox.shrink();
    return SessionStripFact(
      key: const ValueKey('overview-peek-place'),
      icon: AppIcons.folder,
      label: place,
      tooltip: 'Runs in $place',
    );
  }
}
