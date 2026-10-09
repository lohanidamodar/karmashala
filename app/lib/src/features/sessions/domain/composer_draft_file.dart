import 'package:flutter/foundation.dart';

/// A file in a composer's box, kept with its half-typed text while no view of
/// the session is open. Already on a disk — the composer's attachments
/// folder, this machine's own file, or the server — never bytes in memory.
/// Only the composer reads [payload] back.
@immutable
class ComposerDraftFile {
  const ComposerDraftFile({required this.path, required this.payload});

  /// Where the file is: one path is one file, however many views kept it.
  final String path;
  final Object payload;
}
