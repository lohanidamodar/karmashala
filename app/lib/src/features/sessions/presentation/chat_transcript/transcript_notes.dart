// Notes and answered cards in the transcript: interruptions, background runs, plans, questions, errors.

part of '../chat_transcript.dart';

/// Claude Code's own "[Request interrupted by user…]" lines.
final _interruptionNote = RegExp(r'^\[Request interrupted by user[^\]]*\]$');

/// An interruption, said quietly on the agent's side: a muted line, since
/// the person did not type it.
class _InterruptionNote extends StatelessWidget {
  const _InterruptionNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final words = text.contains('tool use')
        ? 'Interrupted: you stopped the tool call'
        : 'Interrupted by you';
    return Row(
      children: [
        Icon(AppIcons.stopCircle, size: Chrome.iconSmall, color: muted),
        const SizedBox(width: Insets.sm),
        Flexible(
          child: Text(
            words,
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
      ],
    );
  }
}

/// A background run's completion, said quietly under the run's own name.
class _BackgroundRunNote extends StatelessWidget {
  const _BackgroundRunNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(AppIcons.checkCircle, size: Chrome.iconSmall, color: muted),
        const SizedBox(width: Insets.sm),
        Flexible(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
      ],
    );
  }
}

/// What the CLI said about the session — a hook's message, say — in a muted
/// line, since neither the person nor the agent said it.
class _TranscriptNote extends StatelessWidget {
  const _TranscriptNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Row(
      key: const ValueKey('transcript-notice'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(AppIcons.info, size: Chrome.iconSmall, color: muted),
        const SizedBox(width: Insets.sm),
        Flexible(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
      ],
    );
  }
}

/// A plan the agent asked to carry out, after the person answered: the plan
/// in its words under whether it was approved. A refused plan is the tool's
/// error (Claude's "keep planning").
class _AnsweredPlanCard extends StatelessWidget {
  const _AnsweredPlanCard({required this.tool});

  final ToolActivity tool;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final approved = !tool.isError;
    final tone = approved ? SemanticColors.of(context).idle : scheme.outline;
    return TranscriptTurnFrame(
      edge: scheme.outlineVariant,
      padding: const EdgeInsets.all(Insets.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectionContainer.disabled(
            child: Row(
              children: [
                Icon(
                  approved ? AppIcons.checkCircle : AppIcons.listChecks,
                  size: Chrome.iconSmall,
                  color: tone,
                ),
                const SizedBox(width: Insets.xs),
                Flexible(
                  child: Text(
                    approved
                        ? 'Plan approved'
                        : 'Plan not approved: kept planning',
                    style: theme.textTheme.labelMedium?.copyWith(color: tone),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Insets.sm),
          MarkdownMessage(tool.proposedPlan!),
        ],
      ),
    );
  }
}

/// The questions the agent asked, after the person answered: each question
/// over the answer it got, or "answered in a message" when none came back
/// here.
class _AnsweredQuestionsCard extends StatelessWidget {
  const _AnsweredQuestionsCard({required this.questions});

  final List<AskedQuestion> questions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return TranscriptTurnFrame(
      edge: scheme.outlineVariant,
      padding: const EdgeInsets.all(Insets.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectionContainer.disabled(
            child: Row(
              children: [
                Icon(
                  AppIcons.question,
                  size: Chrome.iconSmall,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: Insets.xs),
                Text(
                  questions.length == 1
                      ? 'Asked you a question'
                      : 'Asked you ${questions.length} questions',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          for (final q in questions) ...[
            const SizedBox(height: Insets.sm),
            Text(q.question, style: theme.textTheme.bodyMedium),
            Text(
              q.answer ?? 'Answered in a message',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: q.answer == null ? null : FontWeight.w600,
                color: q.answer == null ? scheme.onSurfaceVariant : null,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ErrorMessageCard extends StatelessWidget {
  const _ErrorMessageCard({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final failure = semantic.failure;
    return TranscriptTurnFrame(
      fill: semantic.failureSurface,
      edge: failure.withValues(alpha: SemanticColors.surfaceEdgeAlpha),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(AppIcons.warningCircle, size: Chrome.iconSmall, color: failure),
          const SizedBox(width: Insets.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectionContainer.disabled(
                  child: Text(
                    'ERROR',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: failure,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: Insets.xs),
                Text(
                  message.text,
                  style: theme.textTheme.bodySmall?.copyWith(color: failure),
                ),
              ],
            ),
          ),
          _CopyButton(text: message.text),
        ],
      ),
    );
  }
}
