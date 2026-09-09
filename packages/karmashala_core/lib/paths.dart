/// Whether a stored path still resolves — a measurement, not state.
///
/// See CLAUDE.md §20: the reparse walk distinguishes a path that is missing
/// from one the OS refuses to traverse.
library;

export 'src/paths/path_probe.dart';
