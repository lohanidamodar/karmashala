import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../application/session_plan_providers.dart';
import '../../application/session_status_providers.dart';
import 'plan_update_card.dart';

/// **The latest plan, pinned compactly above the composer while a turn
/// runs**: progress and the item the agent is on, opening into the list.
/// Nothing at all between turns — the transcript holds the plan then.
class PinnedPlanStrip extends ConsumerStatefulWidget {
  const PinnedPlanStrip({required this.sessionId, super.key});

  final String sessionId;

  @override
  ConsumerState<PinnedPlanStrip> createState() => _PinnedPlanStripState();
}

class _PinnedPlanStripState extends ConsumerState<PinnedPlanStrip> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final running = ref.watch(
      agentSessionStatusProvider(widget.sessionId).select(
        (status) => switch (status.asData?.value.status) {
          AgentActivityStatus.working ||
          AgentActivityStatus.awaitingApproval => true,
          _ => false,
        },
      ),
    );
    if (!running) return const SizedBox.shrink();
    final plan = ref.watch(sessionAgentPlanProvider(widget.sessionId)).plan;
    if (plan == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final current = plan.current?.text.split('\n').first;
    final progress = '${plan.doneCount}/${plan.total}';
    return Padding(
      key: const ValueKey('pinned-plan'),
      padding: const EdgeInsets.only(bottom: Insets.xs),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: _open,
            label: 'Plan, $progress done${current == null ? '' : ', on $current'}',
            excludeSemantics: true,
            child: InkWell(
              onTap: () => setState(() => _open = !_open),
              borderRadius: BorderRadius.circular(Radii.sm),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: UiDensity.of(context).isTouch
                      ? Touch.target
                      : Chrome.row,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
                  child: Row(
                    children: [
                      Icon(
                        _open ? AppIcons.caretDown : AppIcons.caretRight,
                        size: Chrome.iconSmall,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: Insets.xs),
                      Icon(
                        AppIcons.listChecks,
                        size: Chrome.iconSmall,
                        color: plan.isFinished
                            ? semantic.idle
                            : semantic.working,
                      ),
                      const SizedBox(width: Insets.sm),
                      Text(
                        'Plan $progress',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (current != null) ...[
                        const SizedBox(width: Insets.sm),
                        Expanded(
                          child: Text(
                            current,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_open)
            ConstrainedBox(
              // A long list may not push the composer away.
              constraints: const BoxConstraints(maxHeight: 160),
              child: SingleChildScrollView(
                primary: false,
                padding: const EdgeInsets.fromLTRB(
                  Insets.lg + Insets.sm,
                  0,
                  Insets.sm,
                  Insets.xs,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final item in plan.items)
                      PlanChecklistRow(item: item, maxLines: 2),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
