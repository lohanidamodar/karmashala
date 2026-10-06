import 'dart:io';

import 'package:agent_cli/process.dart' show CommandException, formatBytes;
import 'package:riverpod/riverpod.dart';

import '../../../app/shell/reveal_in_file_manager.dart';
import '../../../core/process/command_runner_providers.dart';

/// Bytes as Settings → Server shows them.
String describeBytes(int bytes) => formatBytes(bytes);

/// Hands this machine's server files to the host's file manager or default
/// app. Each call answers null, or why it could not, in a person's words.
class ServerFiles {
  ServerFiles(this._ref);

  final Ref _ref;

  Future<String?> revealFolder(String path) async {
    final manager = HostFileManager.forHost();
    if (manager == null) {
      return 'This platform has no file manager Karmashala can open.';
    }
    try {
      await _ref
          .read(hostCommandRunnerProvider)
          .run(RevealInFileManager.requestFor(manager, path));
      return null;
    } on CommandException catch (error) {
      return 'Could not open the folder: ${error.message}';
    }
  }

  Future<String?> openLog(String path) async {
    final manager = HostFileManager.forHost();
    if (manager == null) {
      return 'This platform has no way for Karmashala to open a file.';
    }
    if (!File(path).existsSync()) {
      return 'The server has not written its log yet.';
    }
    try {
      await _ref
          .read(hostCommandRunnerProvider)
          .run(RevealInFileManager.requestFor(manager, path));
      return null;
    } on CommandException catch (error) {
      return 'Could not open the server log: ${error.message}';
    }
  }
}

final serverFilesProvider = Provider<ServerFiles>(ServerFiles.new);
