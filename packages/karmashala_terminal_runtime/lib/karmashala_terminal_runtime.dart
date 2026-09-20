/// What a terminal does. `karmashala_terminal_core` is what one *is*.
///
/// Nothing has to import this: each entry library above is narrow on purpose,
/// and a caller names the one it means.
library;

export 'host_link.dart';
export 'ingest.dart';
export 'instances.dart';
export 'launch.dart';
export 'persistence.dart';
export 'recording.dart';
export 'screen_reading.dart';
export 'scrollback.dart';
export 'system_terminals.dart';
export 'themes.dart';
