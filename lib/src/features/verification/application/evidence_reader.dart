import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Reads a run's evidence off the UI thread.
///
/// The pane used to answer both of its questions synchronously — `existsSync()`
/// beside every screenshot, and `readAsStringSync()` for a whole artifact file
/// when a tile was opened. The comment defending the read argued that a few
/// hundred kilobytes is cheap, which is true of the bytes and false of the
/// wait: an artifact directory can sit on a `\\wsl.localhost` share, where a
/// single synchronous stat measures 1.19 ms against 0.07 ms locally (the same
/// number `importedTranscriptProvider` cites), and a 200 KB read on top of it
/// is several frames of a window that is not repainting.
///
/// A provider rather than bare `dart:io` in the widget, because that is what
/// makes the asynchronous version testable at all: `verification_pane_test.dart`
/// records that awaiting real file I/O inside `testWidgets` never completes,
/// `tester.runAsync` included. The seam that makes it fast is the seam that
/// makes it provable.
class VerificationEvidenceReader {
  const VerificationEvidenceReader();

  /// Whether [path] is still on disk.
  Future<bool> exists(String path) => File(path).exists();

  /// The text of [path], or null when it is not on disk any more.
  ///
  /// No `exists()` ahead of the read: that would be a second round trip to
  /// answer a question the read answers itself.
  Future<String?> read(String path) async {
    try {
      return await File(path).readAsString();
    } on PathNotFoundException {
      return null;
    }
  }
}

final verificationEvidenceReaderProvider = Provider<VerificationEvidenceReader>(
  (ref) => const VerificationEvidenceReader(),
);
