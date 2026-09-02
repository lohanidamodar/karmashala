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

/// The shortest gap between two **focus-driven** re-listings.
///
/// The same number and the same reasoning as `kDeliveryFocusRefreshInterval`:
/// focus is not a rare event — a tiling window manager crosses it dozens of
/// times a minute — so an alt-tab storm must cost one refresh rather than one
/// per tab.
const Duration kFileListingRefreshInterval = Duration(seconds: 30);

/// Ticks when the Files panel's directory listings should be read from disk
/// again.
///
/// **Why this exists.** [directoryListingProvider] is `autoDispose`, which
/// disposes a listing nobody is watching but caches one that stays on screen
/// *forever*. The owner deleted twenty-one merged `wt-*` worktrees from disk
/// and the panel went on offering all twenty-one, because nothing had asked
/// the filesystem again since the folder was first expanded. A folder that has
/// gone must stop being offered.
///
/// **Why focus rather than a watcher.** `DirectoryChangeWatcher` exists and
/// Quick Open's index uses it, but every path this panel lists is a WSL path
/// reached from Windows over 9p, where a recursive `ReadDirectoryChangesW` is
/// both unreliable and expensive — and the change that prompted this was made
/// from a shell outside the app, which no in-app signal (`CheckoutMoved` and
/// friends) would ever have reported. Re-listing when the user comes back to
/// the window is the cheap version that catches every case: it costs one
/// listing per *expanded* folder, at most once per
/// [kFileListingRefreshInterval], and only when somebody is actually looking.
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

/// Directory contents for [windowsDir], listed on the Windows host.
///
/// Re-read whenever [fileListingRefreshProvider] ticks, which is what keeps a
/// deleted folder from being offered indefinitely; see that controller for why
/// the signal is focus and not a filesystem watch.
final directoryListingProvider = FutureProvider.autoDispose
    .family<List<DirEntry>, String>((ref, windowsDir) async {
      ref.watch(fileListingRefreshProvider);
      return ref.read(fileListingServiceProvider).list(windowsDir);
    });

/// What a host path is. Asked **once per click**, never while rendering.
///
/// A seam, because that is the claim this feature has to keep: the transcript
/// decides what to underline on shape alone, and the only `stat` in the whole
/// path happens here, after the reader has asked for something.
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

  /// The host path, spelled the way [DirEntry.windowsPath] spells one — the
  /// listing runs on the host through `dart:io`, so the tree and the target
  /// have to agree on that.
  final String hostPath;

  /// A file is selected; a folder is only opened. Nothing is *opened in an
  /// editor* either way — the pane already does that when a row is tapped, and
  /// a second, deliberate click is where that belongs.
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

/// Where the Files panel has been asked to go, or null.
///
/// Held rather than fired as an event because it is *selection*, not an
/// action: the row stays highlighted after the tree has finished opening, and
/// a target that arrives while the panel is closed is still there when it
/// opens. The panel drives itself down to it — see [FileRevealRole].
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

/// One host path, in the form two of them can be compared in.
///
/// Case-folded because the two hosts this app is used on — Windows and macOS —
/// have case-insensitive filesystems, and a target that came from a transcript
/// is spelled by an agent rather than by the listing. On Linux this can in
/// principle match the wrong one of two files differing only in case; the cost
/// is selecting the neighbour, and the alternative is failing to select
/// anything on the two platforms that matter most.
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

/// What [entryPath] has to do about [target].
///
/// A pure function so a row can ask it inside a `select`: every row runs this
/// on every change of the target, but only the handful whose answer *changed*
/// is rebuilt.
FileRevealRole fileRevealRoleFor(
  FileRevealTarget? target,
  String entryPath, {
  required bool isDirectory,
}) {
  if (target == null) return FileRevealRole.none;
  final wanted = fileTreeKey(target.hostPath);
  final here = fileTreeKey(entryPath);
  if (wanted == here) return FileRevealRole.target;
  if (isDirectory && wanted.startsWith('$here/')) return FileRevealRole.onTheWay;
  return FileRevealRole.none;
}
