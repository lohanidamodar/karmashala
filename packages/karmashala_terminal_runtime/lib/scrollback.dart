/// Keeping a pane's history. The codec that turns a buffer into the text a
/// layout row stores and back, the park that lifts the scrollback off a
/// terminal being resized, the byte-bounded spool a hidden pane fills, and the
/// cold screen that lets a pane keep receiving while nothing is decoding it.
library;

export 'src/cold_screen.dart';
export 'src/scrollback_codec.dart';
export 'src/scrollback_park.dart';
export 'src/scrollback_replay.dart';
export 'src/scrollback_spool.dart';
