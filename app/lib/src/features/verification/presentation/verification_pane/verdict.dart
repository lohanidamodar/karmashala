// The verdict line and chip, and a meta row.

part of '../verification_pane.dart';

/// The verdict, who graded it, then [child] taking the rest. The chip and the
/// mark take a third of the row each at most: "unattributed" at 1.3x text is
/// most of a 240px panel.
class _VerdictLine extends StatelessWidget {
  const _VerdictLine({required this.run, required this.child});

  final VerificationRun run;
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Row(
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: constraints.maxWidth / 3),
          child: _VerdictChip(run: run),
        ),
        const SizedBox(width: Insets.xs),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: constraints.maxWidth / 3),
          child: AttributionMark(attribution: run.attribution),
        ),
        const SizedBox(width: Insets.sm),
        Expanded(child: child),
      ],
    ),
  );
}

class _VerdictChip extends StatelessWidget {
  const _VerdictChip({required this.run});

  final VerificationRun run;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final look = verdictAppearance(run.verdict, SemanticColors.of(context));
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.xs,
        vertical: Insets.hair,
      ),
      decoration: BoxDecoration(
        color: look.color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(look.icon, size: Chrome.iconSmall, color: look.color),
          const SizedBox(width: Insets.xs),
          Flexible(
            child: Text(
              look.label.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: look.color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

const _sectionTitlePadding = EdgeInsets.only(bottom: Insets.sm);

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LabeledValueRow(
      label: label,
      labelStyle: theme.textTheme.labelSmall,
      padding: const EdgeInsets.only(bottom: Insets.xxs),
      value: SelectableText(value, style: theme.textTheme.bodySmall),
    );
  }
}
