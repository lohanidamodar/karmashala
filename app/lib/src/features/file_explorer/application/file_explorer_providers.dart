import 'package:agent_cli/process.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_files/values.dart';
import 'package:karmashala_terminal_core/geometry.dart';

import '../../../core/data/data_client.dart' show DataLinkState;
import '../../../core/data/data_providers.dart';
import '../../editor/domain/document_id.dart';
import '../../explorer/application/project_head.dart'
    show windowRefocusCountProvider;
import '../../files/data/files_client.dart';
import '../../git/application/changes_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../../workspaces/data/workspace_data.dart';

/// The Files panel's root: the selected repository, where its own
/// environment has it — this machine, a WSL distribution, an SSH host alike.
/// Null when nothing is selected.
final fileTreeRootProvider = Provider<EnvironmentPath?>((ref) {
  final id = ref.watch(selectedRepositoryIdProvider);
  if (id == null) return null;
  return ref.watch(workspaceDataProvider).repository(id)?.path;
});

/// Ticks when the person asks for the listings again — the Refresh button.
class FileListingRefreshController extends Notifier<int> {
  @override
  int build() => 0;

  void refresh() => state++;
}

final fileListingRefreshProvider =
    NotifierProvider<FileListingRefreshController, int>(
      FileListingRefreshController.new,
    );

/// The entries of [directory], listed by the server when the folder is first
/// shown, and again on Refresh, when the window comes back to the front, when
/// the link to the server comes back, and after this app's own operation
/// changed it. Never watched: a watcher over the WSL share or SSH costs more
/// than a listing.
final directoryListingProvider = FutureProvider.autoDispose
    .family<List<FileEntry>, EnvironmentPath>((ref, directory) async {
      ref.watch(fileListingRefreshProvider);
      final listedAt = DateTime.now();
      ref.listen(windowRefocusCountProvider, (_, _) {
        if (DateTime.now().difference(listedAt) < kListingRefocusFloor) return;
        ref.invalidateSelf();
      });
      ref.listen(dataConnectionProvider, (previous, next) {
        final was = previous?.value?.state;
        if (next.value?.state != DataLinkState.connected) return;
        if (was == null || was == DataLinkState.connected) return;
        ref.invalidateSelf();
      });
      final files = ref.read(filesClientProvider);
      final key = pathKey(directory);
      final touched = files.listingsTouched.listen((folder) {
        if (pathKey(folder) == key) ref.invalidateSelf();
      });
      ref.onDispose(touched.cancel);
      return files.list(directory);
    });

/// A path the Files panel should open down to and select.
@immutable
class FileRevealTarget {
  const FileRevealTarget({required this.path, required this.isDirectory});

  final EnvironmentPath path;

  /// A file is selected; a folder is only opened. Nothing is opened in an
  /// editor either way — a tap already does that.
  final bool isDirectory;

  @override
  bool operator ==(Object other) =>
      other is FileRevealTarget &&
      other.path == path &&
      other.isDirectory == isDirectory;

  @override
  int get hashCode => Object.hash(path, isDirectory);
}

/// What one row has to do about the current [FileRevealTarget].
enum FileRevealRole {
  /// Nothing. The answer for every row but the handful on the way down.
  none,

  /// An ancestor of the target: open, so the next one down can be listed.
  onTheWay,

  /// The target itself: select it, and scroll it into view.
  target,
}

/// Where the Files panel has been asked to go, or null. Held rather than
/// fired: it is selection, and a target set while closed survives to opening.
class FileRevealController extends Notifier<FileRevealTarget?> {
  @override
  FileRevealTarget? build() => null;

  void reveal(FileRevealTarget target) => state = target;

  void clear() => state = null;
}

final fileRevealTargetProvider =
    NotifierProvider<FileRevealController, FileRevealTarget?>(
      FileRevealController.new,
    );

/// One path in the form two of them can be compared in, its environment
/// included: `/home/me/app` in WSL and on a host are not one folder.
String fileTreeKey(EnvironmentPath path) => pathKey(path);

/// Whether [path] is [root] or lives under it.
bool isUnderFileTreeRoot(EnvironmentPath root, EnvironmentPath path) {
  final rootKey = fileTreeKey(root);
  final key = fileTreeKey(path);
  return key == rootKey || key.startsWith('$rootKey/');
}

/// What [entryPath] has to do about [target]. Pure, so a row can ask it inside
/// a `select` and only the handful whose answer changed rebuild.
FileRevealRole fileRevealRoleFor(
  FileRevealTarget? target,
  EnvironmentPath entryPath, {
  required bool isDirectory,
}) {
  if (target == null) return FileRevealRole.none;
  final wanted = fileTreeKey(target.path);
  final here = fileTreeKey(entryPath);
  if (wanted == here) return FileRevealRole.target;
  if (isDirectory && wanted.startsWith('$here/')) {
    return FileRevealRole.onTheWay;
  }
  return FileRevealRole.none;
}

/// The file open in the focused pane of the active workbench tab, where its
/// own environment has it — null when that pane is not an editor.
final activeEditorPathProvider = Provider<EnvironmentPath?>((ref) {
  final paneId = ref.watch(
    terminalSessionsControllerProvider.select(
      (state) => state.activeTab?.focusedPaneId,
    ),
  );
  if (paneId == null) return null;
  final documentId = editorPanePath(paneId);
  return documentId == null ? null : documentPathOf(documentId);
});
