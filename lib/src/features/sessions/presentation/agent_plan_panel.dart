import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/pane_scaffold.dart';
import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../core/util/clock_provider.dart';
import 'package:agent_cli/descriptors.dart';
import '../../explorer/application/session_context.dart';
import '../application/session_chat_source.dart';
import '../application/session_plan_providers.dart';
import '../application/session_ui_providers.dart';
import '../domain/session_resume.dart' show describeAge;

/// Which session's plan the panel is describing.
///
/// The session **on screen**, not the one last clicked in the Explorer — the
/// same rule [mediaPanelSessionIdProvider] follows, and for the same reason:
/// switching terminal tabs changes which agent you are looking at.
///
/// **One session, not four.** The panel answers "which of my agents is stuck"
/// by being one tab-switch from each of them, rather than by subscribing to
/// every pane's transcript at once — that would be four whole-transcript
/// parses on the UI isolate per tick, which is the cost
/// [chatTranscriptPollingProvider] exists to have stopped paying.
final planPanelSessionIdProvider = Provider<String?>(
  (ref) =>
      ref.watch(activePaneSessionIdProvider) ??
      ref.watch(selectedSessionIdProvider),
);

/// **The agent's own plan, beside its pane.**
///
/// Not the user's todo list — that is [TodosView], one glyph up the rail, and
/// the two are deliberately different surfaces. This one is read-only by
/// construction: it is a record of what the agent said it intended, and an
/// editable copy of somebody else's plan would be a third list to keep in step.
///
/// Everything expensive is upstream: [sessionAgentPlanProvider] folds a list
/// the conversation's own poll already produced, so opening this adds no read,
/// no parse and no timer. The consequence is that the reading can be old, and
/// **every state below says how old** — a plan that has been overtaken looks
/// exactly like a current one, and that is the failure this panel would
/// otherwise be.
class AgentPlanPanel extends ConsumerWidget {
  const AgentPlanPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionId = ref.watch(planPanelSessionIdProvider);
    if (sessionId == null) {
      return const PanePlaceholder(
        message: 'Open a session to see the plan its agent is working to.',
        icon: AppIcons.clipboardText,
      );
    }

    final reading = ref.watch(sessionAgentPlanProvider(sessionId));
    final plan = reading.plan;
    if (plan == null) {
      return _Absence(reading: reading);
    }

    final now = ref.watch(clockProvider).nowUtc();
    return ListView(
      padding: const EdgeInsets.only(bottom: Insets.lg),
      children: [
        _PlanSummary(reading: reading, now: now),
        if (plan.note.isNotEmpty) _Note(plan.note),
        for (final item in plan.items) _PlanRow(item: item),
      ],
    );
  }
}

/// The line that answers the glance: how far along, and how old the reading is.
class _PlanSummary extends StatelessWidget {
  const _PlanSummary({required this.reading, required this.now});

  final AgentPlanReading reading;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final plan = reading.plan!;
    final finished = plan.isFinished;
    final stalled = reading.isStaleAt(now);
    // Three states, three colours, because telling a finished list from an
    // abandoned one at a glance is the whole point of the surface.
    final colour = finished
        ? semantic.idle
        : (stalled ? semantic.attention : semantic.working);
    final age = reading.ageAt(now);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.md,
        Insets.md,
        Insets.md,
        Insets.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                finished ? AppIcons.checkCircle : AppIcons.circleHalf,
                size: Chrome.icon,
                color: colour,
              ),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Text(
                  finished
                      ? 'All ${plan.total} done'
                      : '${plan.doneCount} of ${plan.total} done',
                  style: theme.textTheme.titleSmall?.copyWith(color: colour),
                ),
              ),
            ],
          ),
          const SizedBox(height: Insets.xs),
          // **§19, at the line the reading is on.** An unknown reading time is
          // not a reading time, so a plan whose transcript line carried no
          // timestamp says that rather than borrowing "just now".
          Text(
            age == null
                ? 'Written at an unknown time'
                : 'Written ${describeAge(age)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (stalled)
            Padding(
              padding: const EdgeInsets.only(top: Insets.xs),
              child: Text(
                // Not "this agent is stuck". The reading is that the plan has
                // not moved, which is a fact; being stuck is a diagnosis this
                // app has no evidence for.
                'Unchanged for over '
                '${kPlanGoesStaleAfter.inMinutes} minutes',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: semantic.attention,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Codex's `explanation` — the agent's own sentence about the plan as a whole.
class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.md,
        0,
        Insets.md,
        Insets.sm,
      ),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }
}

/// One item, in the agent's own words.
class _PlanRow extends StatelessWidget {
  const _PlanRow({required this.item});

  final AgentPlanItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final (glyph, colour) = switch (item.state) {
      AgentPlanItemState.completed => (AppIcons.checkCircle, semantic.idle),
      AgentPlanItemState.inProgress => (AppIcons.circleHalf, semantic.working),
      AgentPlanItemState.pending => (AppIcons.circle, scheme.onSurfaceVariant),
      // A word the CLI has started using that we have not been taught. Shown,
      // and shown as unknown — never folded into "pending", which would be a
      // guess, and never dropped, which would lose real work.
      AgentPlanItemState.unrecorded => (AppIcons.question, semantic.neutral),
    };
    final done = item.state == AgentPlanItemState.completed;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.md,
        vertical: Insets.xs,
      ),
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

/// **Which nothing this is**, in words, and what to do about it where there is
/// something to do (§19's `SystemCheck.remedy` rule).
class _Absence extends ConsumerWidget {
  const _Absence({required this.reading});

  final AgentPlanReading reading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final message = switch (reading.absence) {
      AgentPlanAbsence.agentPublishesNone =>
        reading.refusal.isEmpty
            ? 'This agent does not publish a plan.'
            : 'This agent does not publish a plan.\n\n${reading.refusal}',
      AgentPlanAbsence.noneYet =>
        'This agent has not written a plan in this conversation yet.',
      // Why, in the reading's own words: an agent whose store nothing here
      // opens is a different sentence from a session whose transcript file is
      // simply not on this disk, and the hedge used to cover both.
      AgentPlanAbsence.noRecord =>
        reading.refusal.isEmpty
            ? 'No record of this session we can read.'
            : 'No record of this session we can read.\n\n${reading.refusal}',
      // The one that has a remedy, and the honest name for the gap: nothing
      // here polls, so the transcript is only re-read while a conversation is
      // the surface in front.
      AgentPlanAbsence.notRead || null => ref.watch(chatTranscriptPollingProvider)
          ? 'Reading this session’s record…'
          : 'Not read yet — the transcript is re-read only while a '
                'conversation is on screen. Open this session’s chat view '
                'to refresh it.',
    };
    return PanePlaceholder(
      message: message,
      icon: reading.absence == AgentPlanAbsence.agentPublishesNone
          ? AppIcons.minusCircle
          : AppIcons.clipboardText,
    );
  }
}
