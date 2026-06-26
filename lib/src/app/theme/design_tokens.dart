import 'package:flutter/material.dart';

/// Design tokens for Chitragupta's visual identity.
///
/// Theme: *the keeper of the ledger*. Chitragupta records every deed; the app
/// records every agent session in an append-only log. The identity is **ink &
/// brass on parchment** — deep indigo ink for structure, a brass accent for what
/// is alive or important, warm neutral surfaces, and a monospace "ledger hand"
/// for paths, ids, and events.
class AppColors {
  const AppColors._();

  /// Deep indigo "ink" — the primary structural colour.
  static const ink = Color(0xFF302B63);
  static const inkBright = Color(0xFF4B43A8);

  /// Brass — illumination; used for live/important state, sparingly.
  static const brass = Color(0xFFBE8A2E);
  static const brassBright = Color(0xFFD9A441);

  /// Warm parchment surfaces (light).
  static const parchment = Color(0xFFFBF8F2);
  static const parchmentDim = Color(0xFFF1ECE1);

  /// Slate surfaces (dark).
  static const slate = Color(0xFF15131F);
  static const slateRaised = Color(0xFF1E1B2C);

  static const danger = Color(0xFFB3261E);
}

/// Spacing scale (4-pt base). Use these instead of ad-hoc paddings.
class Insets {
  const Insets._();
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

/// Corner radii.
class Radii {
  const Radii._();
  static const sm = 6.0;
  static const md = 10.0;
  static const lg = 14.0;
  static const Radius card = Radius.circular(md);
}

/// Motion durations.
class Motion {
  const Motion._();
  static const fast = Duration(milliseconds: 120);
  static const base = Duration(milliseconds: 220);
}

/// A monospace stack for the "ledger hand" — paths, ids, event types, diffs.
const String kMonoFamily = 'monospace';
