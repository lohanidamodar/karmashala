// Option rows, clamped text, badges and CompanionChoice of the card.

part of '../question_prompt_card.dart';

/// Text held to [lines] with a "more" to show it whole, offered only when it
/// does not fit.
class _Clamped extends StatelessWidget {
  const _Clamped({
    required this.textKey,
    required this.toggleKey,
    required this.text,
    required this.style,
    required this.lines,
    required this.whole,
    required this.onToggle,
  });

  final Key textKey;
  final Key toggleKey;
  final String text;
  final TextStyle? style;
  final int lines;
  final bool whole;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: DefaultTextStyle.of(context).style.merge(style),
        ),
        maxLines: lines,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: box.maxWidth);
      final overflows = painter.didExceedMaxLines;
      painter.dispose();
      final shown = Text(
        text,
        key: textKey,
        style: style,
        maxLines: whole ? null : lines,
        overflow: whole ? null : TextOverflow.ellipsis,
      );
      if (!overflows && !whole) return shown;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onToggle,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            shown,
            Text(
              whole ? 'less' : 'more',
              key: toggleKey,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// One option as a dense row: a radio, or a box when several may be chosen;
/// the label with a "Recommended" badge in place of the agent's suffix; the
/// description held to two lines unless chosen or opened.
class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required super.key,
    required this.id,
    required this.label,
    required this.description,
    required this.multi,
    required this.selected,
    required this.onTap,
    required this.dense,
    this.number,
    this.opened = false,
    this.preview = '',
    this.previewOpen = false,
    this.onToggleOpen,
    this.onTogglePreview,
  });

  /// `question-option` key suffix for the row's parts.
  final String id;
  final String label;
  final String description;
  final bool multi;
  final bool selected;
  final bool opened;
  final bool dense;

  /// Drawn in place of the radio: the key that picks this option.
  final int? number;

  /// The chosen option's preview; empty when it has none or is not chosen.
  final String preview;
  final bool previewOpen;
  final VoidCallback? onTap;
  final VoidCallback? onToggleOpen;
  final VoidCallback? onTogglePreview;

  static final _recommended = RegExp(
    r'\s*\(recommended\)',
    caseSensitive: false,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    final recommended = _recommended.hasMatch(label);
    final name = recommended
        ? label.replaceFirst(_recommended, '').trim()
        : label;
    final icon = multi
        ? (selected ? AppIcons.check : AppIcons.square)
        : (selected ? AppIcons.checkCircle : AppIcons.circle);
    final hasDescription = description.isNotEmpty && description != label;
    final whole = selected || opened;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        onLongPress: hasDescription ? onToggleOpen : null,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: density.isTouch ? _touchRow : 0,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Insets.xxs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: Insets.xxs),
                  child: number == null
                      ? Icon(
                          icon,
                          size: density.icon,
                          color: selected
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        )
                      : _NumberCap(number: number!, selected: selected),
                ),
                SizedBox(width: density.glyphGap + 2),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Wrap(
                        spacing: Insets.xs + 2,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(name, style: theme.textTheme.bodyMedium),
                          if (recommended) const _Badge('Recommended'),
                        ],
                      ),
                      if (hasDescription) _description(context, whole: whole),
                      if (preview.isNotEmpty) ..._preview(context),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _description(BuildContext context, {required bool whole}) {
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    final style = density.muted(theme);
    final lines = dense ? 1 : 2;
    final chevron = density.isTouch ? 32.0 : 24.0;
    return LayoutBuilder(
      builder: (context, box) {
        final painter = TextPainter(
          text: TextSpan(
            text: description,
            style: DefaultTextStyle.of(context).style.merge(style),
          ),
          maxLines: lines,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: box.maxWidth - chevron);
        final overflows = painter.didExceedMaxLines;
        painter.dispose();
        // A chosen option's description is always whole: no chevron to fold.
        final canFold = !selected && (overflows || opened);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                description,
                key: ValueKey('question-option-desc-$id'),
                style: style,
                maxLines: whole ? null : lines,
                overflow: whole ? null : TextOverflow.ellipsis,
              ),
            ),
            if (canFold)
              SizedBox.square(
                dimension: chevron,
                child: IconButton(
                  key: ValueKey('question-option-expand-$id'),
                  padding: EdgeInsets.zero,
                  iconSize: density.iconSmall,
                  tooltip: opened ? 'Show less' : 'Show more',
                  onPressed: onToggleOpen,
                  icon: Icon(opened ? AppIcons.caretUp : AppIcons.caretDown),
                ),
              )
            else
              SizedBox(width: chevron),
          ],
        );
      },
    );
  }

  List<Widget> _preview(BuildContext context) => [
    TextButton(
      key: ValueKey('question-preview-toggle-$id'),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
        visualDensity: UiDensity.of(context).controlDensity,
      ),
      onPressed: onTogglePreview,
      child: Text(previewOpen ? 'Hide preview' : 'Show preview'),
    ),
    if (previewOpen)
      Container(
        key: ValueKey('question-preview-$id'),
        constraints: const BoxConstraints(maxHeight: 240),
        padding: const EdgeInsets.all(Insets.sm),
        decoration: BoxDecoration(
          color: SurfaceTones.of(context).term,
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        // Drawn as written: a mockup's columns are its meaning.
        child: SingleChildScrollView(
          primary: false,
          child: SingleChildScrollView(
            primary: false,
            scrollDirection: Axis.horizontal,
            child: SelectableText(
              preview,
              style: MonoStyles.body.copyWith(
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
        ),
      ),
  ];
}

/// An option's number in a small box, filled when chosen.
class _NumberCap extends StatelessWidget {
  const _NumberCap({required this.number, required this.selected});

  final int number;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final side = UiDensity.of(context).icon;
    return Container(
      constraints: BoxConstraints(minWidth: side, minHeight: side),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected ? scheme.primary : null,
        border: Border.all(
          color: selected ? scheme.primary : scheme.outlineVariant,
        ),
        borderRadius: BorderRadius.circular(Insets.xs),
      ),
      child: Text(
        '$number',
        style: theme.textTheme.labelSmall?.copyWith(
          color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// A word in a small rounded tag beside a label.
class _Badge extends StatelessWidget {
  const _Badge(this.word);

  final String word;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.xsm,
        vertical: Insets.hair,
      ),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: StateLayers.selectedAlpha),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Text(
        word,
        style: theme.textTheme.labelSmall?.copyWith(color: accent),
      ),
    );
  }
}

/// One option to tap: a radio, or a box when several may be chosen.
class CompanionChoice extends StatelessWidget {
  const CompanionChoice({
    super.key,
    required this.label,
    required this.description,
    required this.multi,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String description;
  final bool multi;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    final icon = multi
        ? (selected ? AppIcons.check : AppIcons.square)
        : (selected ? AppIcons.checkCircle : AppIcons.circle);
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: density.minRow),
          child: Row(
            children: [
              Icon(
                icon,
                size: density.icon,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
              SizedBox(width: density.glyphGap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(label, style: theme.textTheme.bodyMedium),
                    if (description.isNotEmpty && description != label)
                      Text(
                        description,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
