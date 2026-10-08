import 'package:flutter/material.dart';
import 'package:karmashala_ui/tokens.dart';

/// One face of a [ViewSwitch].
class ViewSwitchSegment<T> {
  const ViewSwitchSegment({
    required this.value,
    required this.icon,
    required this.label,
    required this.tooltip,
    this.badge,
    this.key,
  });

  final T value;
  final IconData icon;
  final String label;

  /// Also the semantics label, which a glyph-only segment still needs.
  final String tooltip;

  /// A count beside the glyph: the Files view's changed files.
  final String? badge;
  final Key? key;
}

/// **The views of one session** — Chat, Terminal, Files — as one small group:
/// a raised well with the chosen face lifted in the selection tone, no
/// outline. Glyphs alone unless [labelled]; each face keeps its tooltip and
/// semantics label either way.
class ViewSwitch<T> extends StatelessWidget {
  const ViewSwitch({
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.labelled = false,
    this.touch = false,
    super.key,
  });

  final List<ViewSwitchSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onChanged;
  final bool labelled;

  /// Each face at least [Touch.target] square, for a phone's app bar.
  final bool touch;

  @override
  Widget build(BuildContext context) => Container(
    clipBehavior: Clip.antiAlias,
    padding: const EdgeInsets.all(Insets.hair),
    decoration: BoxDecoration(
      color: SurfaceTones.of(context).raised,
      borderRadius: BorderRadius.circular(Radii.sm),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final segment in segments)
          _ViewSwitchFace(
            key: segment.key,
            segment: segment,
            selected: segment.value == selected,
            labelled: labelled,
            touch: touch,
            onTap: () => onChanged(segment.value),
          ),
      ],
    ),
  );
}

class _ViewSwitchFace<T> extends StatelessWidget {
  const _ViewSwitchFace({
    required this.segment,
    required this.selected,
    required this.labelled,
    required this.touch,
    required this.onTap,
    super.key,
  });

  final ViewSwitchSegment<T> segment;
  final bool selected;
  final bool labelled;
  final bool touch;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colour = selected ? scheme.onSurface : scheme.onSurfaceVariant;
    final small = theme.textTheme.labelSmall?.copyWith(color: colour);
    return Tooltip(
      message: segment.tooltip,
      child: Semantics(
        button: true,
        selected: selected,
        label: segment.tooltip,
        child: InkWell(
          onTap: onTap,
          child: Container(
            constraints: touch
                ? const BoxConstraints(
                    minWidth: Touch.target,
                    minHeight: Touch.target,
                  )
                : null,
            alignment: touch ? Alignment.center : null,
            // Padded rather than fixed: a face grows with the ambient text
            // scale, or the row loses its shared centre-line.
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.sm,
              vertical: Insets.xxs + Insets.hair,
            ),
            decoration: BoxDecoration(
              color: selected
                  ? SurfaceTones.of(context).selected
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(Radii.sm - Insets.hair),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  segment.icon,
                  size: touch ? Touch.icon : Chrome.iconSmall,
                  color: colour,
                ),
                if (labelled) ...[
                  const SizedBox(width: Insets.xs),
                  Text(segment.label, style: small),
                ],
                // Beside the glyph, not over it: a badge on a 13px glyph
                // hid the glyph at large text.
                if (segment.badge case final badge?) ...[
                  const SizedBox(width: Insets.xxs),
                  Text(
                    badge,
                    style: small?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
