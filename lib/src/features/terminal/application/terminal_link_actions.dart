import 'dart:io';

import 'package:riverpod/riverpod.dart';

import '../../../app/shell/reveal_in_file_manager.dart';
import '../../editor/application/code_editor_providers.dart';
import 'package:agent_cli/process.dart';
import '../../git/application/remote_links.dart';

/// What is at a resolved path.
enum TerminalPathKind { file, directory }

/// Everything a Ctrl+click in a terminal pane needs from outside the widget.
///
/// One injected seam rather than three providers read in a `State`, so a test
/// records what a click *would* have done instead of starting a browser, an
/// editor or Explorer on the machine running the suite — and so [kindOf], the
/// only filesystem call anywhere on this path, can be answered without a real
/// directory tree.
abstract interface class TerminalLinkActions {
  /// Opens a URL outside the app.
  Future<void> openUrl(String url);

  /// What is at [hostPath], or null when nothing is.
  ///
  /// Asked once per candidate, after detection has already decided the text is
  /// path-shaped, and never while scanning a line.
  Future<TerminalPathKind?> kindOf(String hostPath);

  /// Opens [hostPath]. Returns a message to put in front of the user, or null
  /// when it worked.
  ///
  /// [line] and [column] are the `path:12:7` the output carried. Nothing
  /// honours them yet — `EditorActions.openPath` takes a path and nothing else
  /// — but they are threaded this far so that honouring them later is a change
  /// to one method rather than to the whole path.
  Future<String?> open(
    String hostPath,
    TerminalPathKind kind, {
    int? line,
    int? column,
  });
}

/// The app's [TerminalLinkActions]: the same openers every other surface uses.
///
/// A directory reveals in the host's file manager ([RevealInFileManager], which
/// the Explorer and the Files panel also use); a file opens in the configured
/// code editor ([EditorActions], which is what "open in editor" means
/// everywhere else); a URL keeps the browser behaviour that already shipped.
class AppTerminalLinkActions implements TerminalLinkActions {
  AppTerminalLinkActions(this._ref);

  final Ref _ref;

  @override
  Future<void> openUrl(String url) async {
    await _ref.read(openExternalUrlProvider)(url);
  }

  @override
  Future<TerminalPathKind?> kindOf(String hostPath) async {
    // Follows links, so a symlinked directory is a directory. A path we cannot
    // even stat (a permission error, a dead UNC host) is "nothing there",
    // which is the same answer as missing and the same silence.
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
    try {
      await _ref.read(editorActionsProvider).openPath(hostPath);
      return null;
    } catch (error) {
      return error is StateError ? error.message : '$error';
    }
  }
}

final terminalLinkActionsProvider = Provider<TerminalLinkActions>(
  (ref) => AppTerminalLinkActions(ref),
);
