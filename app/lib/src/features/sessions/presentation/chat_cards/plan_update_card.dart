import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../domain/plan_changes.dart';

/// **The agent's plan where it wrote it in the conversation** — `TodoWrite`,
/// `update_plan` or an ACP plan update. The first is drawn whole; each later
/// one says what moved, with the whole list a tap away.
class PlanUpdateCard extends StatefulWidget {
  const PlanUpdateCard({required this.plan, this.previous, super.key});

  final AgentPlan plan;

  /// The plan this one replaced, or null when it is the first one held.
  final AgentPlan? previous;

  @override
  State<PlanUpdateCard> createState() => _PlanUpdateCardState();
}

class _PlanUpdateCardState extends State<PlanUpdateCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final plan = widget.plan;
    final previous = widget.previous;
    final changes = planChanges(previous, plan);
    final update = previous != null;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final colour = plan.isFinished ? semantic.idle : semantic.working;
    final noteChanged = plan.note.isNotEmpty && plan.note != previous?.note;

    return TranscriptCardFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(AppIcons.listChecks, size: Chrome.iconSmall, color: colour),
              const SizedBox(width: Insets.sm),
              Text(
                update ? 'Plan updated' : 'Plan',
                style: theme.textTheme.labelLarge,
              ),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Text(
                  plan.isFinished
                      ? 'All ${plan.total} done'
                      : '${plan.doneCount} of ${plan.total} done',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: muted,
                ),
              ),
              if (update)
                TextButton(
                  onPressed: () => setState(() => _open = !_open),
                  child: Text(_open ? 'Hide plan' : 'Show plan'),
                ),
            ],
          ),
          if (noteChanged)
            Padding(
              padding: const EdgeInsets.only(top: Insets.xs),
              child: Text(
                plan.note,
                style: muted?.copyWith(fontStyle: FontStyle.italic),
              ),
            ),
          const SizedBox(height: Insets.xs),
          if (!update || _open)
            for (final item in plan.items) PlanChecklistRow(item: item)
          else if (changes.isEmpty)
            Text('Nothing on it changed.', style: muted)
          else
            for (final change in changes) _ChangeRow(change: change),
        ],
      ),
    );
  }
}

/// The quiet frame a plan card sits in: the tool rows' tone, without their
/// header, since a plan is the agent's own words rather than a call's output.
class TranscriptCardFrame extends StatelessWidget {
  const TranscriptCardFrame({required this.child, this.edge, super.key});

  final Widget child;
  final Color? edge;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? scheme.surfaceContainerLowest
            : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: edge ?? scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.md,
          vertical: Insets.sm,
        ),
        child: child,
      ),
    );
  }
}

/// One plan item with its state's glyph, as the side panel draws it.
class PlanChecklistRow extends StatelessWidget {
  const PlanChecklistRow({required this.item, this.maxLines, super.key});

  final AgentPlanItem item;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final (glyph, colour) = planItemGlyph(item.state, scheme, semantic);
    final done = item.state == AgentPlanItemState.completed;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(glyph, size: Chrome.iconSmall, color: colour),
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Semantics(
              label: '${item.state.name}: ${item.text}',
              child: Text(
                item.text,
                maxLines: maxLines,
                overflow: maxLines == null ? null : TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: done ? scheme.onSurfaceVariant : scheme.onSurface,
                  decoration: done ? TextDecoration.lineThrough : null,
                  decorationColor: scheme.onSurfaceVariant,
                  fontWeight: item.state == AgentPlanItemState.inProgress
                      ? FontWeight.w600
                      : null,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A plan item state's glyph and colour. An unrecorded word is shown as
/// unknown — never folded into pending.
(IconData, Color) planItemGlyph(
  AgentPlanItemState state,
  ColorScheme scheme,
  SemanticColors semantic,
) => switch (state) {
  AgentPlanItemState.completed => (AppIcons.checkCircle, semantic.idle),
  AgentPlanItemState.inProgress => (AppIcons.circleHalf, semantic.working),
  AgentPlanItemState.pending => (AppIcons.circle, scheme.onSurfaceVariant),
  AgentPlanItemState.unrecorded => (AppIcons.question, semantic.neutral),
};

class _ChangeRow extends StatelessWidget {
  const _ChangeRow({required this.change});

  final PlanChange change;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final (word, glyph, colour) = switch (change.kind) {
      PlanChangeKind.completed => (
        'Completed',
        AppIcons.checkCircle,
        semantic.idle,
      ),
      PlanChangeKind.started => ('Started', AppIcons.circleHalf, semantic.working),
      PlanChangeKind.added => ('Added', AppIcons.plus, scheme.onSurfaceVariant),
      PlanChangeKind.dropped => (
        'Dropped',
        AppIcons.minusCircle,
        scheme.onSurfaceVariant,
      ),
    };
    final style = theme.textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(glyph, size: Chrome.iconSmall, color: colour),
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '$word  ',
                    style: style?.copyWith(
                      color: colour,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  TextSpan(
                    text: change.text,
                    style: style?.copyWith(
                      color: scheme.onSurface,
                      decoration: change.kind == PlanChangeKind.dropped
                          ? TextDecoration.lineThrough
                          : null,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
