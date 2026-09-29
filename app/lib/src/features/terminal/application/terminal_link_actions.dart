import 'dart:io';

import 'package:riverpod/riverpod.dart';

import '../../../app/shell/reveal_in_file_manager.dart';
import '../../../core/capabilities/capabilities.dart';
import '../../editor/application/editor_tab_actions.dart';
import '../../files/data/files_client.dart';
import 'package:agent_cli/process.dart';
import '../../git/application/remote_links.dart';

/// What is at a resolved path.
enum TerminalPathKind { file, directory }

/// Everything a Ctrl+click in a pane needs from outside the widget. One seam,
/// so a test records what a click would do and [kindOf] needs no real tree.
abstract interface class TerminalLinkActions {
  /// Opens a URL outside the app.
  Future<void> openUrl(String url);

  /// What is at [hostPath], or null when nothing is. Asked once per candidate,
  /// after detection decided the text is path-shaped, never while scanning.
  Future<TerminalPathKind?> kindOf(String hostPath);

  /// Opens [hostPath], returning a message to show or null when it worked.
  /// [line] is scrolled to; [column] is threaded but not honoured yet.
  Future<String?> open(
    String hostPath,
    TerminalPathKind kind, {
    int? line,
    int? column,
  });
}

/// The app's [TerminalLinkActions]: a directory reveals through
/// [RevealInFileManager], a file opens in an editor tab, a URL goes to the
/// browser — the same openers every other surface uses.
class AppTerminalLinkActions implements TerminalLinkActions {
  AppTerminalLinkActions(this._ref);

  final Ref _ref;

  @override
  Future<void> openUrl(String url) async {
    await _ref.read(openExternalUrlProvider)(url);
  }

  bool get _readsServerDisk =>
      _ref.read(capabilitiesProvider).readsServerDisk;

  @override
  Future<TerminalPathKind?> kindOf(String hostPath) async {
    // A pane's paths are the server's; one elsewhere is asked, not this disk.
    if (!_readsServerDisk) {
      try {
        final stat = await _ref
            .read(filesClientProvider)
            .stat(
              EnvironmentPath(
                environmentId: localHostEnvironmentId,
                path: hostPath,
              ),
            );
        if (!stat.exists) return null;
        return stat.isDirectory
            ? TerminalPathKind.directory
            : TerminalPathKind.file;
      } on Object {
        return null;
      }
    }
    // Follows links, so a symlinked directory is a directory. A path that
    // cannot even be stat-ed — a permission error, a dead UNC host — is
    // "nothing there", the same answer and the same silence as missing.
    try {
      return switch (await FileSystemEntity.type(hostPath)) {
        FileSystemEntityType.notFound => null,
        FileSystemEntityType.directory => TerminalPathKind.directory,
        _ => TerminalPathKind.file,
      };
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<String?> open(
    String hostPath,
    TerminalPathKind kind, {
    int? line,
    int? column,
  }) async {
    if (kind == TerminalPathKind.directory) {
      if (!_readsServerDisk) {
        return '$hostPath is a folder on the server; nothing here can show it.';
      }
      final outcome = await _ref
          .read(revealInFileManagerProvider)
          .reveal(
            EnvironmentPath(
              environmentId: localHostEnvironmentId,
              path: hostPath,
            ),
          );
      return outcome.ok ? null : outcome.error;
    }
    _ref.read(editorTabActionsProvider).open(hostPath, line: line);
    return null;
  }
}

final terminalLinkActionsProvider = Provider<TerminalLinkActions>(
  (ref) => AppTerminalLinkActions(ref),
);
