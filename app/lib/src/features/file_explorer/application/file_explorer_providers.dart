import '../../editor/data/local_document_source.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'dart:io';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../editor/application/code_editor_providers.dart';
import '../../git/application/changes_providers.dart';
import '../../notifications/application/notification_providers.dart';
import '../../repositories/application/repository_providers.dart';
import '../data/file_listing_service.dart';

final fileListingServiceProvider = Provider<FileListingService>(
  (ref) => const FileListingService(),
);

/// The selected repository's root as a Windows-host path (for the file
/// explorer), or `null` if none is selected / it can't be resolved.
final selectedRepoWindowsRootProvider = Provider<String?>((ref) {
  final id = ref.watch(selectedRepositoryIdProvider);
  if (id == null) return null;
  final repo = ref.watch(repositoryDaoProvider).getById(id);
  if (repo == null) return null;
  return ref.read(editorActionsProvider).windowsPathFor(repo.path);
});

/// The shortest gap between two **focus-driven** re-listings: focus is not a
/// rare event, so an alt-tab storm must cost one refresh rather than one a tab.
const Duration kFileListingRefreshInterval = Duration(seconds: 30);

/// Ticks when the Files panel's listings should be read from disk again.
/// Focus, not a watcher: these are WSL paths over 9p, changed from outside.
class FileListingRefreshController extends Notifier<int> {
  /// When the last re-read was asked for. Mounting counts: the listings read
  /// as soon as they are first watched.
  DateTime? _lastAsked;

  @override
  int build() {
    final clock = ref.watch(clockProvider);
    ref.listen(windowFocusedProvider, (previous, next) {
      // Only a genuine regain, and only once the window has been seen to lose
      // focus — the first `true` at startup is not a return to the app.
      if (!next || previous != false) return;
      final now = clock.nowUtc();
      final last = _lastAsked;
      if (last != null && now.difference(last) < kFileListingRefreshInterval) {
        return;
      }
      _ask(now);
    });
    _lastAsked = clock.nowUtc();
    return 0;
  }

  /// The Refresh button, and anything else that knows the tree moved. Not rate
  /// limited: an explicit click is the user telling us they know better.
  void refresh() => _ask(ref.read(clockProvider).nowUtc());

  void _ask(DateTime now) {
    _lastAsked = now;
    state++;
  }
}

final fileListingRefreshProvider =
    NotifierProvider<FileListingRefreshController, int>(
      FileListingRefreshController.new,
    );

/// Directory contents for [windowsDir], listed on the Windows host, re-read
/// whenever [fileListingRefreshProvider] ticks so a deleted folder stops.
final directoryListingProvider = FutureProvider.autoDispose
    .family<List<DirEntry>, String>((ref, windowsDir) async {
      ref.watch(fileListingRefreshProvider);
      return ref.read(fileListingServiceProvider).list(windowsDir);
    });

/// What a host path is. Asked **once per click**, never while rendering — the
/// transcript underlines on shape alone, and this is the only `stat`.
typedef HostPathProbe = FileSystemEntityType Function(String hostPath);

final hostPathProbeProvider = Provider<HostPathProbe>(
  (ref) => (path) {
    try {
      return FileSystemEntity.typeSync(path, followLinks: true);
    } on FileSystemException {
      // A path this platform rejects, or a share that went away. Not there is
      // the honest answer, and it is the one the caller can say out loud.
      return FileSystemEntityType.notFound;
    }
  },
);

/// A path the Files panel should open down to and select.
@immutable
class FileRevealTarget {
  const FileRevealTarget({required this.hostPath, required this.isDirectory});

  /// The host path, spelled the way [DirEntry.windowsPath] spells one: the
  /// listing runs on the host, so the tree and the target must agree.
  final String hostPath;

  /// A file is selected; a folder is only opened. Nothing is opened in an
  /// editor either way — a tap already does that.
  final bool isDirectory;

  @override
  bool operator ==(Object other) =>
      other is FileRevealTarget &&
      other.hostPath == hostPath &&
      other.isDirectory == isDirectory;

  @override
  int get hashCode => Object.hash(hostPath, isDirectory);
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

/// One host path in the form two of them can be compared in. Case-folded for
/// Windows and macOS; on Linux that can pick the neighbour of a case pair.
String fileTreeKey(String path) {
  var normalized = path.replaceAll(r'\', '/').toLowerCase();
  while (normalized.length > 1 && normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}

/// Whether [path] is [root] or lives under it.
bool isUnderFileTreeRoot(String root, String path) {
  final rootKey = fileTreeKey(root);
  final key = fileTreeKey(path);
  return key == rootKey || key.startsWith('$rootKey/');
}

/// What [entryPath] has to do about [target]. Pure, so a row can ask it inside
/// a `select` and only the handful whose answer changed rebuild.
FileRevealRole fileRevealRoleFor(
  FileRevealTarget? target,
  String entryPath, {
  required bool isDirectory,
}) {
  if (target == null) return FileRevealRole.none;
  final wanted = fileTreeKey(target.hostPath);
  final here = fileTreeKey(entryPath);
  if (wanted == here) return FileRevealRole.target;
  if (isDirectory && wanted.startsWith('$here/')) {
    return FileRevealRole.onTheWay;
  }
  return FileRevealRole.none;
}

/// The file open in the focused pane of the active workbench tab, as a host
/// path — null when that pane is not an editor, or its file is only reachable
/// over a connection.
final activeEditorHostPathProvider = Provider<String?>((ref) {
  final paneId = ref.watch(
    terminalSessionsControllerProvider.select(
      (state) => state.activeTab?.focusedPaneId,
    ),
  );
  if (paneId == null) return null;
  final documentId = editorPanePath(paneId);
  return documentId == null ? null : hostPathOfDocument(documentId);
});
