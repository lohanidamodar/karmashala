import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/process.dart'
    show EnvironmentPath, localHostEnvironmentId;
import 'package:flutter/painting.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/capabilities/capabilities.dart';
import '../../files/data/files_client.dart';

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

  /// The image at [path], or null when it is gone.
  Future<ImageProvider?> image(String path) async =>
      await exists(path) ? FileImage(File(path)) : null;
}

/// Evidence on a server elsewhere: the run's paths are the server's own, so
/// they are read through it rather than off this disk.
class ServerEvidenceReader implements VerificationEvidenceReader {
  const ServerEvidenceReader(this._files);

  final FilesClient _files;

  EnvironmentPath _at(String path) =>
      EnvironmentPath(environmentId: localHostEnvironmentId, path: path);

  @override
  Future<bool> exists(String path) async =>
      (await _files.stat(_at(path))).exists;

  @override
  Future<String?> read(String path) async {
    if (!await exists(path)) return null;
    // The pane shows at most 200K characters; no need to carry a whole log.
    final bytes = await _files.read(_at(path), length: 1024 * 1024);
    return utf8.decode(bytes, allowMalformed: true);
  }

  @override
  Future<ImageProvider?> image(String path) async {
    if (!await exists(path)) return null;
    return MemoryImage(await _files.read(_at(path)));
  }
}

final verificationEvidenceReaderProvider = Provider<VerificationEvidenceReader>(
  (ref) => ref.watch(capabilitiesProvider.select((c) => c.readsServerDisk))
      ? const VerificationEvidenceReader()
      : ServerEvidenceReader(ref.watch(filesClientProvider)),
);
