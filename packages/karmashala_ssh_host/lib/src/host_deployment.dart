import 'dart:typed_data';

import 'package:meta/meta.dart';

/// A compiled host binary and the version it reports.
@immutable
class HostBinary {
  const HostBinary({
    required this.length,
    required this.readBytes,
    required this.version,
    required this.source,
    this.candidates = 1,
    this.isBundleArchive = false,
  });

  /// How big it is, which is all the deployer needs to decide whether the
  /// machine already has it. Kept separate from [readBytes] so the common case —
  /// already installed — never reads the file.
  final int length;

  /// The contents, read only once an upload is actually going to happen.
  final Future<Uint8List> Function() readBytes;

  /// Whether [bytes] are a gzipped tar of a `dart build cli` bundle rather than
  /// an executable. A bundle cannot be flattened: the executable finds the
  /// SQLite it was built with at `../lib`, so it is unpacked, never chmod-ed in
  /// place. False is a host from before the store, which is still one file.
  final bool isBundleArchive;

  /// Taken from the filename, which the build script stamps. It is compared
  /// against what the *remote* binary answers, never trusted on its own.
  final String version;

  /// Where it came from, so a failure names a path a person can look at.
  final String source;

  /// How many files matched this target where [source] was found. More than one
  /// means older builds sit beside it, so a notice can say which was taken.
  final int candidates;
}
