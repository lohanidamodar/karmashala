import 'package:flutter/material.dart';

import 'design_tokens.dart';

/// [leading] and [trailing] side by side, or [trailing] under [leading] once the
/// width this widget is given drops below [breakpoint] (grown with the text
/// scale). The label-left/control-right row the settings screen wrote by hand.
///
/// Measures its own constraints, so it must not sit where intrinsics are asked
/// for — an `AlertDialog`'s content or a popup menu item.
class StackWhenNarrow extends StatelessWidget {
  const StackWhenNarrow({
    required this.breakpoint,
    required this.leading,
    required this.trailing,
    this.spacing = Insets.lg,
    this.runSpacing = Insets.xs,
    this.trailingMaxWidth,
    this.stackedAlignment = CrossAxisAlignment.start,
    super.key,
  });

  /// The narrowest width, at 1x text, that still holds both on one line.
  final double breakpoint;

  /// Takes the free width side by side.
  final Widget leading;

  /// Its own width side by side, capped at [trailingMaxWidth].
  final Widget trailing;

  /// Between the two, side by side.
  final double spacing;

  /// Between the two, stacked.
  final double runSpacing;

  final double? trailingMaxWidth;

  /// How the stacked pair aligns; [CrossAxisAlignment.stretch] for a field that
  /// should take the whole width once it is on its own line.
  final CrossAxisAlignment stackedAlignment;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth <
            WidthClass.scaleBreakpoint(breakpoint, scaler)) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: stackedAlignment,
            children: [
              leading,
              SizedBox(height: runSpacing),
              trailing,
            ],
          );
        }
        final max = trailingMaxWidth;
        return Row(
          children: [
            Expanded(child: leading),
            SizedBox(width: spacing),
            if (max == null)
              trailing
            else
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: max),
                child: trailing,
              ),
          ],
        );
      },
    );
  }
}
