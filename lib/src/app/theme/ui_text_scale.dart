import 'package:flutter/widgets.dart';

/// The UI text sizes Settings offers, as multipliers of the design size.
const List<double> uiTextScaleOptions = [0.9, 1.0, 1.1, 1.25, 1.5];

/// Applies the user's UI text scale on top of the OS's. Installed above the
/// Navigator, so menus, dialogs, tooltips and snackbars inherit it too.
class UiTextScale extends StatelessWidget {
  const UiTextScale({required this.scale, required this.child, super.key});

  /// The user's multiplier (1.0 = 100%).
  final double scale;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(
        textScaler: composeTextScaler(media.textScaler, scale),
      ),
      child: child,
    );
  }
}

/// The [system] scaler with [uiScale] multiplied on, so Windows' "make text
/// bigger" and the app's own setting compound rather than fight.
TextScaler composeTextScaler(TextScaler system, double uiScale) {
  final systemFactor = system.scale(14.0) / 14.0;
  final combined = systemFactor * uiScale;
  return combined == 1.0 ? TextScaler.noScaling : TextScaler.linear(combined);
}
