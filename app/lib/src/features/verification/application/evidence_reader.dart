import 'dart:io';

import 'package:riverpod/riverpod.dart';

/// Reads a run's evidence off the UI thread: one synchronous stat on a WSL
/// share measures 1.19 ms against 0.07 ms locally. A provider, so tests can fake it.
class VerificationEvidenceReader {
  const VerificationEvidenceReader();

  /// Whether [path] is still on disk.
  Future<bool> exists(String path) => File(path).exists();

  /// The text of [path], or null when it is gone. No `exists()` ahead of the
  /// read: a second round trip to answer what the read answers itself.
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
