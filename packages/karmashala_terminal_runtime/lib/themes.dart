/// Terminal themes the host already has: where Ghostty and Warp keep theirs,
/// and the two readers that turn one into a palette. Both parsers are pure
/// over a string and neither throws, so a malformed theme is skipped rather
/// than crashing the terminal that asked for it.
library;

export 'src/ghostty_theme.dart';
export 'src/theme_discovery.dart';
export 'src/warp_theme.dart';
