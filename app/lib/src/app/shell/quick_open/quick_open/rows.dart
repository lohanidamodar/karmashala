part of '../quick_open.dart';

// Small pieces of the palette list: a session dot, a header, the empty state.

/// A session's state on a command row, in the colours the rest of the app
/// gives the same states.
class _SessionDotView extends StatelessWidget {
  const _SessionDotView({required this.dot});

  final SessionDot dot;

  @override
  Widget build(BuildContext context) {
    final semantic = SemanticColors.of(context);
    final (color, label) = switch (dot) {
      SessionDot.waiting => (semantic.attention, 'Waiting on you'),
      SessionDot.working => (semantic.working, 'Working'),
      SessionDot.idle => (semantic.idle, 'Idle'),
      SessionDot.stopped => (semantic.neutral, 'Not running'),
      SessionDot.unknown => (semantic.neutral, 'Status unknown'),
    };
    return Padding(
      padding: const EdgeInsets.only(right: Insets.sm),
      child: StatusDot(color: color, label: label),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Indented to the rows' own inset plus theirs, so the label stands over
    // the glyphs of the group it names.
    return Container(
      height: quickOpenHeaderHeightOf(context),
      alignment: Alignment.bottomLeft,
      padding: const EdgeInsets.only(
        left: Insets.xs + Insets.sm,
        bottom: Insets.xs,
      ),
      child: Text(
        label.toUpperCase(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall
            ?.merge(Chrome.groupLabel)
            .copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.query, this.step});

  final QuickOpenQuery query;

  /// The step the box is in, whose own rows are all that was searched.
  final QuickOpenStep? step;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final group = query.only;
    final step = this.step;
    return Padding(
      padding: const EdgeInsets.all(Insets.xl),
      child: Text(
        step != null
            ? 'Nothing in ${step.title} matches.'
            : group == null
            ? 'Nothing matches.'
            : 'Nothing in ${group.label.toLowerCase()} matches.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
