import 'package:flutter/widgets.dart';

/// Where the mini launcher window sits on screen (one of six edge/corner spots,
/// inset from the work area by a small padding).
enum MiniPosition {
  topLeft,
  topCenter,
  topRight,
  bottomLeft,
  bottomCenter,
  bottomRight;

  /// The [Alignment] this position maps to (consumed by `calcWindowPosition`).
  Alignment get alignment => switch (this) {
    MiniPosition.topLeft => Alignment.topLeft,
    MiniPosition.topCenter => Alignment.topCenter,
    MiniPosition.topRight => Alignment.topRight,
    MiniPosition.bottomLeft => Alignment.bottomLeft,
    MiniPosition.bottomCenter => Alignment.bottomCenter,
    MiniPosition.bottomRight => Alignment.bottomRight,
  };

  String get label => switch (this) {
    MiniPosition.topLeft => 'Top left',
    MiniPosition.topCenter => 'Top center',
    MiniPosition.topRight => 'Top right',
    MiniPosition.bottomLeft => 'Bottom left',
    MiniPosition.bottomCenter => 'Bottom center',
    MiniPosition.bottomRight => 'Bottom right',
  };

  static MiniPosition fromName(Object? value) {
    for (final p in MiniPosition.values) {
      if (p.name == value) return p;
    }
    return MiniPosition.bottomRight;
  }
}
