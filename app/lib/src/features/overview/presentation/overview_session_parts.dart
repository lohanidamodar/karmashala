import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/presentation/agent_logo.dart';
import '../../environments/application/environments_controller.dart';
import '../../explorer/application/agent_states.dart';
import '../../sessions/application/session_status_providers.dart';
import '../application/overview_board.dart';
import '../application/overview_card_line.dart';
import '../application/overview_providers.dart';
import '../application/overview_reads.dart';

/// The colour a state is drawn in on the Overview; null for no colour.
Color? overviewStateColor(BuildContext context, AgentState state) {
  final semantic = SemanticColors.of(context);
  return switch (state) {
    AgentState.needsYou => semantic.attention,
    AgentState.failed => semantic.failure,
    AgentState.working => semantic.working,
    AgentState.ready => semantic.idle,
    AgentState.quiet || AgentState.ended => null,
  };
}

/// What [card] is doing, in words: its status report, the inbox's words and,
/// while it works or waits, one server read of its plan and open calls.
OverviewActivity watchOverviewActivity(WidgetRef ref, OverviewCard card) {
  final id = card.id;
  ref.watch(agentSessionStatusProvider(id));
  final details = ref.watch(overviewInboxDetailsProvider(id));
  final reads =
      card.state == AgentState.working || card.state == AgentState.needsYou;
  final glance = reads
      ? ref.watch(overviewGlanceProvider(id)).asData?.value
      : null;
  return overviewActivity(
    state: card.state,
    report: ref.read(sessionStatusLookupProvider)(id),
    detailOf: (kind) => details[kind],
    activityAt: card.entry.activityAt,
    now: ref.read(clockProvider).nowUtc(),
    glance: glance,
  );
}

/// The headline alone, for a label or a tooltip.
String watchOverviewLine(WidgetRef ref, OverviewCard card) =>
    watchOverviewActivity(ref, card).headline;

/// "karmashala · WSL · arch": where [card] runs.
String watchOverviewPlace(WidgetRef ref, OverviewCard card) {
  final facts = ref.watch(overviewFactsProvider);
  final projectId = facts.projectOf(card.entry);
  final project = facts.projects
      .where((p) => p.id == projectId)
      .firstOrNull
      ?.label;
  final machineId = card.entry.directory?.environmentId;
  final machine = machineId == null
      ? null
      : ref.watch(environmentLabelForIdProvider(machineId));
  final byContext =
      ref.watch(overviewGroupByProvider) == OverviewGroupBy.context;
  final contextId = byContext ? facts.contextOf(card.entry) : null;
  final context = !byContext
      ? null
      : facts.contexts.where((c) => c.id == contextId).firstOrNull?.label ??
            kOverviewNoContextLabel;
  return [?context, ?project, ?machine].join(' · ');
}

/// The agent's display name for [card], or null when it is not known.
String? watchOverviewAgentName(WidgetRef ref, OverviewCard card) {
  final agentId = ref.watch(overviewFactsProvider).agentOf(card.entry);
  return agentId == null
      ? null
      : ref.watch(agentRegistryProvider).displayNameFor(agentId);
}

/// The state's glyph, so a state never rests on colour alone.
class OverviewStateGlyph extends StatelessWidget {
  const OverviewStateGlyph({
    required this.state,
    this.question = false,
    this.size = 13,
    super.key,
  });

  final AgentState state;
  final bool question;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = overviewStateColor(context, state);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return switch (state) {
      AgentState.needsYou => NeedsYouGlyph(size: size, question: question),
      AgentState.working => WorkingSpinner(size: size, color: color!),
      AgentState.failed => Icon(AppIcons.xCircle, size: size, color: color),
      AgentState.ready => Icon(AppIcons.checkCircle, size: size, color: color),
      AgentState.quiet => Icon(AppIcons.pauseCircle, size: size, color: muted),
      AgentState.ended => Icon(AppIcons.checkCircle, size: size, color: muted),
    };
  }
}

/// The agent's logo inside a ring of its state.
class OverviewAgentRing extends ConsumerWidget {
  const OverviewAgentRing({
    required this.card,
    this.size = Chrome.control,
    super.key,
  });

  final OverviewCard card;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final agentId = ref.watch(overviewFactsProvider).agentOf(card.entry);
    final ring = overviewStateColor(context, card.state) ?? scheme.outline;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: scheme.surfaceContainerHigh,
          border: Border.all(color: ring, width: 2),
        ),
        alignment: Alignment.center,
        child: agentId == null
            ? Icon(
                AppIcons.robot,
                size: size / 2,
                color: scheme.onSurfaceVariant,
              )
            : AgentLogo(
                agentId: agentId,
                size: size / 2,
                color: scheme.onSurface,
              ),
      ),
    );
  }
}

/// "Needs you · 6m": the state in words, tinted, with how long.
class OverviewStatePill extends ConsumerWidget {
  const OverviewStatePill({required this.card, super.key});

  final OverviewCard card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final color =
        overviewStateColor(context, card.state) ??
        theme.colorScheme.onSurfaceVariant;
    final now = ref.read(clockProvider).nowUtc();
    final since =
        ref.read(sessionStatusLookupProvider)(card.id)?.waitingSince ??
        card.entry.activityAt;
    return OverviewStateChip(
      state: card.state,
      label: '${card.state.label} · ${compactAge(now.difference(since))}',
      color: color,
    );
  }
}

/// A state's chip: its words on a wash of its colour.
class OverviewStateChip extends StatelessWidget {
  const OverviewStateChip({
    required this.state,
    this.label,
    this.color,
    super.key,
  });

  final AgentState state;

  /// The words, when not the state's own label.
  final String? label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink =
        color ??
        overviewStateColor(context, state) ??
        theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.sm - Insets.xxs,
        vertical: Insets.hair,
      ),
      decoration: BoxDecoration(
        color: ink.withValues(alpha: StateLayers.selectedAlpha),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Text(
        label ?? state.label,
        maxLines: 1,
        style: theme.textTheme.labelSmall?.copyWith(
          color: ink,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// **What a session is doing**, in words, with the command behind it folded
/// away under "Command" — never as the line itself.
class OverviewActivityLine extends ConsumerStatefulWidget {
  const OverviewActivityLine({
    required this.card,
    this.maxLines = 2,
    super.key,
  });

  final OverviewCard card;
  final int maxLines;

  @override
  ConsumerState<OverviewActivityLine> createState() =>
      _OverviewActivityLineState();
}

/// How much of a command the disclosure shows.
const int _kRawShown = 400;

class _OverviewActivityLineState extends ConsumerState<OverviewActivityLine> {
  var _open = false;

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    final activity = watchOverviewActivity(ref, card);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    final urgent =
        card.state == AgentState.needsYou || card.state == AgentState.failed;
    final wait = ref.read(sessionStatusLookupProvider)(card.id)?.waiting;
    final raw = activity.raw;
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: Insets.hair * 3),
              child: OverviewStateGlyph(
                state: card.state,
                question: wait == AgentWaitKind.question,
                size: density.iconSmall + Insets.hair,
              ),
            ),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: Text(
                activity.headline,
                key: ValueKey('overview-activity:${card.id}'),
                maxLines: widget.maxLines,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: urgent
                      ? overviewStateColor(context, card.state)
                      : null,
                ),
              ),
            ),
            if (raw != null)
              Semantics(
                button: true,
                expanded: _open,
                label: _open ? 'Hide the command' : 'Show the command',
                excludeSemantics: true,
                child: InkWell(
                  key: ValueKey('overview-raw-toggle:${card.id}'),
                  borderRadius: BorderRadius.circular(Radii.sm),
                  onTap: () => setState(() => _open = !_open),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          AppIcons.terminal,
                          size: density.iconSmall,
                          color: scheme.onSurfaceVariant,
                        ),
                        Icon(
                          _open ? AppIcons.caretDown : AppIcons.caretRight,
                          size: density.iconSmall,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
        if (raw != null && _open)
          Container(
            key: ValueKey('overview-raw:${card.id}'),
            width: double.infinity,
            margin: const EdgeInsets.only(top: Insets.xs),
            padding: const EdgeInsets.all(Insets.sm),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Command', style: muted),
                const SizedBox(height: Insets.xs),
                SelectableText(
                  raw.length > _kRawShown
                      ? '${raw.substring(0, _kRawShown)}…'
                      : raw,
                  maxLines: 6,
                  style: MonoStyles.small.copyWith(color: scheme.onSurface),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// "Step 3/7 · Fix the peek" over a thin meter.
class OverviewPlanLine extends StatelessWidget {
  const OverviewPlanLine({required this.plan, super.key});

  final AgentPlan plan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final done = plan.isFinished;
    final step = plan.current?.text;
    final words = done
        ? 'Plan done'
        : step ?? 'Plan ${plan.doneCount}/${plan.total} done';
    return Semantics(
      label: 'Plan: ${plan.doneCount} of ${plan.total} done. $words',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                AppIcons.listChecks,
                size: UiDensity.of(context).iconSmall,
                color: muted,
              ),
              const SizedBox(width: Insets.xs),
              Text(
                '${plan.doneCount}/${plan.total}',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Text(
                  words,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(color: muted),
                ),
              ),
            ],
          ),
          const SizedBox(height: Insets.xs),
          LinearMeter(
            value: plan.total == 0 ? 0 : plan.doneCount / plan.total,
            thickness: Insets.xs,
            color: done ? semantic.idle : semantic.working,
            semanticsLabel: 'Plan ${plan.doneCount} of ${plan.total}',
          ),
        ],
      ),
    );
  }
}
