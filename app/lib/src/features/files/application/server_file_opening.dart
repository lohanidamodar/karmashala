import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:path/path.dart' as p;
import 'package:riverpod/riverpod.dart';

import '../../../app/shell/reveal_in_file_manager.dart';
import '../data/files_client.dart';

/// What this machine's own programs do with a file the server holds — the
/// file manager, a double-click's default app (slice 3c). The server names
/// the place ([FilesClient.localPathOf]); nothing here translates a path. A
/// file this machine has no path to — on an SSH host, or behind a server
/// elsewhere — is brought here first, into a temporary folder, to be opened.
class ServerFileOpening {
  const ServerFileOpening(this.files, this.revealer);

  final FilesClient files;
  final RevealInFileManager revealer;

  /// Whether [path] can be shown in this machine's file manager: it must be
  /// on this machine's disk, and a menu asks while it builds.
  bool canReveal(EnvironmentPath path) =>
      revealer.fileManager != null && files.canOpenHere(path);

  /// Whether [path] can be opened as a double-click would — anywhere, since a
  /// file this machine cannot reach is brought here first.
  bool get canOpen => revealer.fileManager != null;

  /// Shows [path] in the file manager, selected when [select].
  Future<RevealOutcome> reveal(
    EnvironmentPath path, {
    bool select = false,
  }) async {
    final String? local;
    try {
      local = await files.localPathOf(path);
    } on FilesException catch (error) {
      return RevealOutcome.failed(error.message);
    }
    if (local == null) {
      return RevealOutcome.failed('${path.path} is not on this machine.');
    }
    return revealer.revealHostPath(local, select: select);
  }

  /// Opens [path] as a double-click would: its default app, or — for a
  /// program — running it.
  Future<RevealOutcome> openWithDefaultApp(EnvironmentPath path) async {
    try {
      final local =
          await files.localPathOf(path) ?? await _download(path);
      return await revealer.revealHostPath(local);
    } on FilesException catch (error) {
      return RevealOutcome.failed(error.message);
    } on FileSystemException catch (error) {
      return RevealOutcome.failed(
        'Could not bring ${path.path} here: '
        '${error.osError?.message ?? error.message}',
      );
    }
  }

  /// [path]'s bytes, read through the server, as a file of the same name in
  /// a folder of its own under this machine's temp directory.
  Future<String> _download(EnvironmentPath path) async {
    final bytes = await files.read(path);
    final folder = await Directory.systemTemp.createTemp('karmashala-open-');
    final name = pathContextOf(path.path).basename(path.path);
    final file = File(p.join(folder.path, name));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }
}

final serverFileOpeningProvider = Provider<ServerFileOpening>(
  (ref) => ServerFileOpening(
    ref.watch(filesClientProvider),
    ref.watch(revealInFileManagerProvider),
  ),
);
