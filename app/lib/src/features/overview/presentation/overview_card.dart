import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_git/github.dart' show ChecksState;
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/presentation/agent_logo.dart';
import '../../environments/application/environments_controller.dart';
import '../../explorer/application/agent_states.dart';
import '../../sessions/application/delivery_providers.dart';
import '../../sessions/application/session_status_providers.dart';
import '../application/overview_board.dart';
import '../application/overview_card_line.dart';
import '../application/overview_prefs.dart';
import '../application/overview_providers.dart';

/// One session on the Board: its state, its agent's mark and title, one line
/// on what it is doing or why it is here, and small chips for where it runs,
/// its branch, its pull request's checks and its sub-sessions. Watches only
/// its own session, so a status push rebuilds one card.
class OverviewCardTile extends ConsumerWidget {
  const OverviewCardTile({
    required this.card,
    required this.density,
    required this.selected,
    required this.onTap,
    this.projectLabel,
    super.key,
  });

  final OverviewCard card;
  final OverviewDensity density;
  final bool selected;
  final VoidCallback onTap;

  /// Named on a card listed outside its project's lane (the phone's list).
  final String? projectLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entry = card.entry;
    final id = entry.id;
    // Watched only to wake: the report itself is read now, never a stale copy.
    ref.watch(agentSessionStatusProvider(id));
    final report = ref.read(sessionStatusLookupProvider)(id);
    final details = ref.watch(overviewInboxDetailsProvider(id));
    final now = ref.read(clockProvider).nowUtc();
    final line = overviewContextLine(
      state: card.state,
      report: report,
      detailOf: (kind) => details[kind],
      activityAt: entry.activityAt,
      now: now,
    );
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tones = SurfaceTones.of(context);
    final density = UiDensity.of(context);
    final muted = density.muted(theme);
    final needsYou = card.column == BoardColumn.needsYou;
    final agentId =
        entry.imported?.cli ??
        switch (entry.native) {
          final native? =>
            ref
                .read(agentInstallationsDataProvider)
                .getById(native.agentInstallationId)
                ?.agentId,
          null => null,
        };
    final agentName = agentId == null
        ? null
        : ref.watch(agentRegistryProvider).displayNameFor(agentId);
    final glyph = _StateGlyph(state: card.state, wait: report?.waiting);
    final title = Text(
      entry.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: density.rowTitle(theme, strong: needsYou),
    );
    final mark = agentId == null
        ? null
        : Tooltip(
            message: agentName ?? agentId,
            child: AgentLogo(agentId: agentId, size: 14),
          );
    final lineText = Text(
      line,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: muted?.copyWith(
        color: needsYou ? SemanticColors.of(context).attention : null,
      ),
    );
    final head = Row(
      children: [
        glyph,
        const SizedBox(width: Insets.xs),
        if (mark != null) ...[mark, const SizedBox(width: Insets.xs)],
        Expanded(child: title),
      ],
    );
    final Widget body = switch (this.density) {
      OverviewDensity.lines => Row(
        children: [
          glyph,
          const SizedBox(width: Insets.xs),
          if (mark != null) ...[mark, const SizedBox(width: Insets.xs)],
          Flexible(flex: 3, child: title),
          const SizedBox(width: Insets.sm),
          Flexible(flex: 2, child: lineText),
        ],
      ),
      OverviewDensity.cards => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (card.breadcrumb case final parent?)
            Text(
              '↳ from $parent',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: muted,
            ),
          head,
          const SizedBox(height: 2),
          lineText,
          _Chips(card: card, projectLabel: projectLabel),
        ],
      ),
    };
    final spoken = [
      card.state.label,
      entry.title,
      ?agentName,
      ?projectLabel,
      line,
      if (card.breadcrumb case final parent?) 'from $parent',
      ?card.children?.label.replaceFirst('↳', 'sub-sessions'),
    ].join(', ');
    return Semantics(
      button: true,
      selected: selected,
      label: spoken,
      excludeSemantics: true,
      child: Opacity(
        opacity: card.dimmed ? 0.6 : 1,
        child: Material(
          color: needsYou ? tones.attentionSurface : scheme.surfaceContainer,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.sm),
            side: BorderSide(
              color: selected
                  ? scheme.primary
                  : needsYou
                  ? tones.attentionEdge
                  : scheme.outlineVariant,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: InkWell(
            key: ValueKey('overview-card:$id'),
            borderRadius: BorderRadius.circular(Radii.sm),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.sm,
                vertical: Insets.xs + 2,
              ),
              child: body,
            ),
          ),
        ),
      ),
    );
  }
}

/// Machine, branch, the pull request's checks and the sub-sessions.
class _Chips extends ConsumerWidget {
  const _Chips({required this.card, this.projectLabel});

  final OverviewCard card;
  final String? projectLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entry = card.entry;
    final directory = entry.directory;
    final machine = directory == null
        ? null
        : ref.watch(environmentLabelForIdProvider(directory.environmentId));
    final branch = _knownBranch(ref, directory);
    final pr = directory == null
        ? null
        : ref.watch(overviewPullRequestProvider(directory));
    final checks = pr?.checks;
    final semantic = SemanticColors.of(context);
    final chips = <Widget>[
      if (projectLabel != null) _Chip(text: projectLabel!),
      if (machine != null) _Chip(text: machine),
      if (branch != null) _Chip(icon: AppIcons.gitBranch, text: branch),
      if (pr != null)
        _Chip(
          icon: AppIcons.gitMerge,
          text: ['#${pr.number}', ?checks?.label].join(' '),
          color: switch (checks?.state) {
            ChecksState.failing => semantic.failure,
            _ => null,
          },
        ),
      if (card.children case final children?)
        _Chip(
          text: children.label,
          color: children.needsYou > 0 ? semantic.attention : null,
        ),
    ];
    if (chips.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: Insets.xs),
      child: Wrap(spacing: Insets.xs, runSpacing: 2, children: chips),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, this.icon, this.color});

  final String text;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = color ?? theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Insets.xs + 1),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: ink),
            const SizedBox(width: 2),
          ],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(color: ink),
            ),
          ),
        ],
      ),
    );
  }
}

/// The branch a reading of [directory] has already named, or null. Borrowed,
/// never asked for, as the Agents lens's rows do.
String? _knownBranch(WidgetRef ref, EnvironmentPath? directory) {
  if (directory == null) return null;
  final checkout = Checkout(directory);
  ref.watch(checkoutReadingsProvider.select((r) => r[checkout]));
  final provider = checkoutDeliveryProvider(checkout);
  if (!ref.exists(provider)) return null;
  return ref.read(provider).asData?.value.branch;
}

/// The state, as the Agents lens draws it: glyph plus label, never colour
/// alone.
class _StateGlyph extends StatelessWidget {
  const _StateGlyph({required this.state, this.wait});

  final AgentState state;
  final AgentWaitKind? wait;

  @override
  Widget build(BuildContext context) {
    const size = 14.0;
    if (state == AgentState.needsYou) {
      return NeedsYouGlyph(
        size: size,
        question: wait == AgentWaitKind.question,
        semanticLabel: state.label,
      );
    }
    final status = switch (state) {
      AgentState.needsYou => AgentActivityStatus.awaitingApproval,
      AgentState.quiet || AgentState.working => AgentActivityStatus.working,
      AgentState.failed => AgentActivityStatus.failed,
      AgentState.ready => AgentActivityStatus.idle,
      AgentState.ended => null,
    };
    if (status != null) {
      return StatusGlyph(
        status: status,
        size: size,
        semanticLabel: state.label,
      );
    }
    return Icon(
      AppIcons.checkCircle,
      size: size,
      semanticLabel: state.label,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
  }
}
