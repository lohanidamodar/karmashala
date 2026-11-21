import 'package:flutter/material.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

/// Lets a detail list put the picker value and its label in one tap target.
class PickerFaceLayout extends InheritedWidget {
  const PickerFaceLayout({required this.wrap, required super.child, super.key});

  final Widget Function(Widget value) wrap;

  @override
  bool updateShouldNotify(PickerFaceLayout oldWidget) => wrap != oldWidget.wrap;
}

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

    final layout = context
        .dependOnInheritedWidgetOfExactType<PickerFaceLayout>();
    if (layout != null) {
      return layout.wrap(_contents(foreground, name, style, inRow: true));
    }
    return TouchTarget(child: _face(scheme, foreground, name, style));
  }

  Widget _face(
    ColorScheme scheme,
    Color foreground,
    Widget name,
    TextStyle? style,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.sm,
        vertical: Insets.tight,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: _contents(foreground, name, style),
    );
  }

  Widget _contents(
    Color foreground,
    Widget name,
    TextStyle? style, {
    bool inRow = false,
  }) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (!inRow || alarming) ...[
        Icon(icon, size: Chrome.iconSmall, color: foreground),
        const SizedBox(width: Insets.xs),
      ],
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
      if (inRow) const SizedBox(width: Insets.xs),
      Icon(AppIcons.caretDown, size: caretSize, color: foreground),
    ],
  );
}
