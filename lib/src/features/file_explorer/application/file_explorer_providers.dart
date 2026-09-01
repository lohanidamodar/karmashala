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
