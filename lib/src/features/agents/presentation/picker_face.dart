import 'package:flutter/material.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

/// The closed face of a model or permission menu: a glyph, a name, its quiet
/// qualifiers and a caret, in one outlined pill. Pure — the menu around it
/// decides what it says.
class PickerFace extends StatelessWidget {
  const PickerFace({
    required this.icon,
    required this.label,
    this.qualifiers = const [],
    this.alarming = false,
    this.maxLabelWidth,
    super.key,
  });

  final IconData icon;
  final String label;

  /// Trailing words a reader must see without hovering: `default`,
  /// `unlisted`, `unrecognised`. Each gives way on its own.
  final List<String> qualifiers;

  /// Tints the whole face in the error colour. Colour carries meaning only.
  final bool alarming;

  /// Caps the name on a wide row. Null leaves it to the row, which still
  /// ellipsises it before anything overflows.
  final double? maxLabelWidth;

  /// A disclosure caret a step under the face's own glyph.
  static const double caretSize = 11;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final foreground = alarming ? scheme.error : scheme.onSurfaceVariant;
    final style = theme.textTheme.labelSmall?.copyWith(color: foreground);

    Widget name = Text(
      label,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
    if (maxLabelWidth case final width?) {
      name = ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width),
        child: name,
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: Chrome.iconSmall, color: foreground),
          const SizedBox(width: Insets.xs),
          Flexible(child: name),
          for (final qualifier in qualifiers) ...[
            const SizedBox(width: Insets.xs),
            Flexible(
              child: Text(
                '· $qualifier',
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
          ],
          Icon(AppIcons.caretDown, size: caretSize, color: foreground),
        ],
      ),
    );
  }
}
