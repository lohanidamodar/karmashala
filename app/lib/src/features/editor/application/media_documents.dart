import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_files/values.dart' show FileStamp;

import '../../../core/capabilities/capabilities.dart'
    show ClientCapabilities, clientCapabilitiesProvider;
import '../../../core/data/data_client.dart' show DataLinkState;
import '../../../core/data/data_providers.dart';
import '../../files/data/files_client.dart';
import '../data/media_store.dart';
import '../domain/document_id.dart';
import '../domain/media_document.dart';
import '../domain/media_kind.dart';

final mediaStoreProvider = Provider<MediaStore>(
  (ref) => MediaStore(ref.watch(filesClientProvider)),
);

/// How long a file's watch must stay quiet before it is reloaded. A film an
/// agent is still rendering fires a watch per write; reloading on each would
/// re-copy it, under a new name, as often as the server could tell. A test
/// overrides it short.
final mediaWatchDebounceProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 1),
);

/// Every open image, video and audio file, keyed by document id
/// (`document_id.dart`) — the media twin of `OpenDocuments`. Absence means
/// "not loaded yet". Held here rather than in the pane for the same reason a
/// buffer is: a pane is built only while its tab is on screen, and switching
/// tabs must not read a 40 MB image, or copy a film, all over again.
///
/// Nothing here is typed into, so a change on disk is simply taken: the watch
/// reloads once the file has settled ([mediaWatchDebounceProvider]), and
/// [MediaDocument.revision] tells the view it is a new picture.
///
/// A client with no media backend ([ClientCapabilities.mediaPlayback] false —
/// a phone) holds video and audio by path and stamp only: it is never read,
/// and a remote one never copied, since nothing here could play it.
class MediaDocuments extends Notifier<Map<String, MediaDocument>> {
  /// The server's watch on each open file: an agent's re-render of a
  /// screenshot is told, not polled for.
  final Map<String, FileWatch> _watches = {};

  /// Each file's pending watch-triggered reload, restarted by every event so
  /// it runs only once the file has stopped changing.
  final Map<String, Timer> _settling = {};

  /// Paths with a load in flight — a remote film's copy can take minutes, and
  /// a second one must not race the first into the cache.
  final Set<String> _loading = {};

  /// Paths whose watch fired while a load was in flight: the load may have
  /// read the version before the change, so one more look follows it.
  final Set<String> _again = {};

  /// Each path's load generation. A load runs under the generation it started
  /// with; a close, or a settled watch event while it copies, moves the
  /// generation on, and the copy stops at its next chunk.
  final Map<String, int> _generation = {};

  /// The files a tab still wants. A load started before a close must not put
  /// its result back afterwards — the bytes would outlive every tab holding
  /// them and be served to whoever opened that file next.
  final Set<String> _wanted = {};

  bool _stillWanted(String hostPath) =>
      ref.mounted && _wanted.contains(hostPath);

  void _supersede(String hostPath) =>
      _generation[hostPath] = (_generation[hostPath] ?? 0) + 1;

  @override
  Map<String, MediaDocument> build() {
    // Back from a lost link to the server: whatever changed while nobody
    // could be told is looked at once, and a file held as unreachable
    // learns it is not.
    ref.listen(dataConnectionProvider, (previous, next) {
      final was = previous?.value?.state;
      if (next.value?.state != DataLinkState.connected) return;
      if (was == null || was == DataLinkState.connected) return;
      for (final path in state.keys) {
        unawaited(reload(path));
      }
    });
    ref.onDispose(() {
      for (final watch in _watches.values) {
        watch.cancel();
      }
      _watches.clear();
      for (final timer in _settling.values) {
        timer.cancel();
      }
      _settling.clear();
    });
    return const {};
  }

  void _watch(String hostPath) {
    if (_watches.containsKey(hostPath)) return;
    _watches[hostPath] = ref
        .read(filesClientProvider)
        .watch(documentPathOf(hostPath), (_) => _settle(hostPath));
  }

  /// A watch event: the reload waits for the file to stop changing.
  void _settle(String hostPath) {
    _settling.remove(hostPath)?.cancel();
    if (!_stillWanted(hostPath)) return;
    _settling[hostPath] = Timer(ref.read(mediaWatchDebounceProvider), () {
      _settling.remove(hostPath);
      unawaited(_reload(hostPath, supersede: true));
    });
  }

  /// Loads [hostPath] unless it is already open or loading. Idempotent: a
  /// restored tab and an explicit open both call it. A path that is not
  /// media ([mediaKindOf] is null) is the text editor's, and ignored here.
  /// Never throws.
  Future<void> open(String hostPath) async {
    if (mediaKindOf(hostPath) == null) return;
    _wanted.add(hostPath);
    _watch(hostPath);
    if (state.containsKey(hostPath) || _loading.contains(hostPath)) return;
    await _load(hostPath);
  }

  /// Looks at [hostPath] on disk again and takes it if it changed, bumping
  /// [MediaDocument.revision]. An unchanged stamp costs one stat and nothing
  /// else. A server that did not answer keeps what is shown and says so in
  /// [MediaDocument.error]; a file gone from disk becomes
  /// [MediaRefusal.notFound]. Never throws.
  Future<void> reload(String hostPath) => _reload(hostPath);

  /// [reload]; [supersede] is a settled watch event — the file on disk is no
  /// longer what a copy in flight is copying, so that copy is stopped and
  /// the newer version loaded after it.
  Future<void> _reload(String hostPath, {bool supersede = false}) async {
    if (!_stillWanted(hostPath)) return;
    if (_loading.contains(hostPath)) {
      _again.add(hostPath);
      if (supersede) _supersede(hostPath);
      return;
    }
    final FileStamp? onDisk;
    try {
      onDisk = await ref.read(mediaStoreProvider).stamp(hostPath);
    } on FilesUnreachableException catch (error) {
      _noteUnreachable(hostPath, error.message);
      return;
    } on Object {
      // A share that did not answer is not evidence the file changed.
      return;
    }
    if (!_stillWanted(hostPath) || _loading.contains(hostPath)) return;
    final now = state[hostPath];
    if (now != null && _sameFile(now.stamp, onDisk)) {
      // The same file, and the server answered: a warning about the link
      // that is now back is dropped. A refusal's own message stays.
      if (now.refusal == MediaRefusal.none && now.error != null) {
        _put(hostPath, now.copyWith(clearError: true));
      }
      return;
    }
    await _load(hostPath);
  }

  /// Reads [hostPath] and puts what it finds, unless a close — or a newer
  /// version of the file — came first.
  Future<void> _load(String hostPath) async {
    final kind = mediaKindOf(hostPath);
    if (kind == null || !_loading.add(hostPath)) return;
    final generation = _generation[hostPath] ?? 0;
    bool cancelled() =>
        !_stillWanted(hostPath) || (_generation[hostPath] ?? 0) != generation;
    // Taken before the load: a copy's progress puts a placeholder in, and a
    // first open is still revision 0.
    final before = _shown(state[hostPath]);
    final next = before == null ? 0 : before.revision + 1;
    var stopped = false;
    try {
      final loaded = await ref
          .read(mediaStoreProvider)
          .load(
            hostPath,
            onProgress: (done) => _noteProgress(hostPath, done),
            isCancelled: cancelled,
            playsHere: ref.read(clientCapabilitiesProvider).mediaPlayback,
          );
      if (cancelled()) {
        stopped = true;
        return;
      }
      // A load that found what is already shown — a watch event for a touch,
      // a reconnect's look at a file that did not move — is not a new
      // picture, and must not make the view drop its zoom or restart a film.
      final revision = before != null && _sameContent(before, loaded)
          ? before.revision
          : next;
      _put(hostPath, loaded.copyWith(revision: revision));
    } on MediaLoadCancelled {
      stopped = true;
    } on FilesUnreachableException catch (error) {
      if (!_stillWanted(hostPath)) return;
      if (before != null) {
        _noteUnreachable(hostPath, error.message);
      } else {
        // Nothing shown yet to keep. A refusal keeps no stamp, so the
        // reconnect's reload reads the file.
        _put(
          hostPath,
          MediaDocument(
            hostPath: hostPath,
            kind: kind,
            refusal: MediaRefusal.unreadable,
            error: error.message,
          ),
        );
      }
    } on Object catch (error) {
      // `load` classifies rather than throws — but an escaped error leaves
      // the pane on a spinner for ever (§5).
      if (!_stillWanted(hostPath)) return;
      _put(
        hostPath,
        MediaDocument(
          hostPath: hostPath,
          kind: kind,
          refusal: MediaRefusal.unreadable,
          error: 'Could not read this file: $error',
          revision: next,
        ),
      );
    } finally {
      _loading.remove(hostPath);
      // A load stopped for a newer version — or for a close the tab took
      // back before the copy noticed — still owes the tab its file.
      final owed = _again.remove(hostPath) || stopped;
      if (owed && _stillWanted(hostPath)) unawaited(reload(hostPath));
    }
  }

  /// [document] unless it is only a first copy's progress placeholder, which
  /// nothing was ever shown from.
  static MediaDocument? _shown(MediaDocument? document) {
    if (document == null) return null;
    final placeholder =
        document.stamp == null &&
        document.refusal == MediaRefusal.none &&
        !document.isReady;
    return placeholder ? null : document;
  }

  /// Whether [loaded] is the version [before] already shows.
  static bool _sameContent(MediaDocument before, MediaDocument loaded) =>
      before.stamp != null &&
      before.refusal == loaded.refusal &&
      before.stamp!.matches(loaded.stamp) &&
      before.localPath == loaded.localPath;

  /// A copy's progress, shown over whatever the tab already plays: a reload
  /// does not blank the old version while the new one arrives.
  void _noteProgress(String hostPath, double done) {
    if (!_stillWanted(hostPath)) return;
    final kind = mediaKindOf(hostPath);
    if (kind == null) return;
    final now = state[hostPath];
    _put(
      hostPath,
      now == null
          ? MediaDocument(hostPath: hostPath, kind: kind, copyProgress: done)
          : now.copyWith(copyProgress: done),
    );
  }

  /// The environment did not answer: the document says so and keeps its
  /// bytes or its path.
  void _noteUnreachable(String hostPath, String reason) {
    final now = state[hostPath];
    if (now == null || !_stillWanted(hostPath)) return;
    if (now.error == reason && now.copyProgress == null) return;
    _put(hostPath, now.copyWith(error: reason, clearCopyProgress: true));
  }

  static bool _sameFile(FileStamp? known, FileStamp? onDisk) =>
      known == null ? onDisk == null : known.matches(onDisk);

  void _put(String hostPath, MediaDocument document) {
    state = {...state, hostPath: document};
  }

  /// Drops the file, stops watching it, and stops any copy of it in flight
  /// (its part file is deleted). A finished copy stays in the cache for the
  /// next open of the same version.
  void close(String hostPath) {
    _wanted.remove(hostPath);
    _again.remove(hostPath);
    _supersede(hostPath);
    _settling.remove(hostPath)?.cancel();
    _watches.remove(hostPath)?.cancel();
    if (!state.containsKey(hostPath)) return;
    state = {...state}..remove(hostPath);
  }
}

final mediaDocumentsProvider =
    NotifierProvider<MediaDocuments, Map<String, MediaDocument>>(
      MediaDocuments.new,
    );

/// One media file, or null while it is still being read.
final mediaDocumentProvider = Provider.family<MediaDocument?, String>(
  (ref, hostPath) =>
      ref.watch(mediaDocumentsProvider.select((open) => open[hostPath])),
);
