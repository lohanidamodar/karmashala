import 'package:flutter/material.dart';

import 'design_tokens.dart';
import 'stepped_ring.dart';

/// Which slot an [InlineSpinner] stands in, and so how big it is drawn.
enum InlineSpinnerSize {
  /// Beside a line of text or inside a dense row — where 12 and 14px spinners
  /// were hand-built. [Chrome.iconAction], or [Touch.iconSmall] for a thumb.
  small,

  /// In a glyph's place — a toolbar button, a button's icon slot — where the
  /// 16px copies were. [Chrome.icon], or [Touch.icon].
  medium,

  /// Centred in a region whose content is loading, the size of the empty
  /// state's glyph it will be replaced by — where the 18–22px copies were.
  /// [Chrome.iconHero], or [Touch.iconHero].
  large;

  /// The square this size occupies under [density].
  double dimensionFor(UiDensity density) => switch (this) {
    small => density.isTouch ? Touch.iconSmall : Chrome.iconAction,
    medium => density.isTouch ? Touch.icon : Chrome.icon,
    large => density.isTouch ? Touch.iconHero : Chrome.iconHero,
  };
}

/// The house indeterminate spinner: a thin ring in a token-sized square. Use it
/// wherever a `SizedBox` around `CircularProgressIndicator(strokeWidth: 2)`
/// would otherwise be written by hand.
///
/// A [SteppedRing] rather than Material's ring: that one holds a vsync
/// [Ticker], so one spinner anywhere on screen put the whole app at 60 full
/// frames a second — measured as ~43 fps of GPU raster on an idle window.
class InlineSpinner extends StatelessWidget {
  const InlineSpinner({
    this.size = InlineSpinnerSize.small,
    this.color,
    this.semanticsLabel,
    super.key,
  });

  final InlineSpinnerSize size;

  /// The ring's colour; the theme's progress colour when null.
  final Color? color;

  /// What a screen reader says. Name the work ("Loading branches") wherever
  /// nothing beside the spinner already does.
  final String? semanticsLabel;

  /// The ring's stroke. Thin at every size: the spinner sits in chrome, and a
  /// Material-weight ring reads as an alarm there.
  static const strokeWidth = 2.0;

  @override
  Widget build(BuildContext context) {
    final colour =
        color ??
        ProgressIndicatorTheme.of(context).color ??
        Theme.of(context).colorScheme.primary;
    return Semantics(
      label: semanticsLabel,
      child: ExcludeSemantics(
        child: SteppedRing(
          size: size.dimensionFor(UiDensity.of(context)),
          color: colour,
          stroke: strokeWidth,
        ),
      ),
    );
  }
}
