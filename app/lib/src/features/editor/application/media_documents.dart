import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_files/values.dart' show FileStamp;

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

/// Every open image, video and audio file, keyed by document id
/// (`document_id.dart`) — the media twin of `OpenDocuments`. Absence means
/// "not loaded yet". Held here rather than in the pane for the same reason a
/// buffer is: a pane is built only while its tab is on screen, and switching
/// tabs must not read a 40 MB image, or copy a film, all over again.
///
/// Nothing here is typed into, so a change on disk is simply taken: the watch
/// reloads, and [MediaDocument.revision] tells the view it is a new picture.
class MediaDocuments extends Notifier<Map<String, MediaDocument>> {
  /// The server's watch on each open file: an agent's re-render of a
  /// screenshot is told, not polled for.
  final Map<String, FileWatch> _watches = {};

  /// Paths with a load in flight — a remote film's copy can take minutes, and
  /// a second one must not race the first into the cache.
  final Set<String> _loading = {};

  /// Paths whose watch fired while a load was in flight: the load may have
  /// read the version before the change, so one more look follows it.
  final Set<String> _again = {};

  /// The files a tab still wants. A load started before a close must not put
  /// its result back afterwards — the bytes would outlive every tab holding
  /// them and be served to whoever opened that file next.
  final Set<String> _wanted = {};

  bool _stillWanted(String hostPath) =>
      ref.mounted && _wanted.contains(hostPath);

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
    });
    return const {};
  }

  void _watch(String hostPath) {
    if (_watches.containsKey(hostPath)) return;
    _watches[hostPath] = ref
        .read(filesClientProvider)
        .watch(documentPathOf(hostPath), (_) => unawaited(reload(hostPath)));
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
  Future<void> reload(String hostPath) async {
    if (!_stillWanted(hostPath)) return;
    if (_loading.contains(hostPath)) {
      _again.add(hostPath);
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

  /// Reads [hostPath] and puts what it finds, unless a close came first.
  Future<void> _load(String hostPath) async {
    final kind = mediaKindOf(hostPath);
    if (kind == null || !_loading.add(hostPath)) return;
    // Taken before the load: a copy's progress puts a placeholder in, and a
    // first open is still revision 0.
    final revision = switch (state[hostPath]) {
      null => 0,
      final before => before.revision + 1,
    };
    try {
      final loaded = await ref
          .read(mediaStoreProvider)
          .load(hostPath, onProgress: (done) => _noteProgress(hostPath, done));
      if (!_stillWanted(hostPath)) return;
      _put(hostPath, loaded.copyWith(revision: revision));
    } on FilesUnreachableException catch (error) {
      if (!_stillWanted(hostPath)) return;
      if (revision > 0) {
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
          revision: revision,
        ),
      );
    } finally {
      _loading.remove(hostPath);
      if (_again.remove(hostPath) && _stillWanted(hostPath)) {
        unawaited(reload(hostPath));
      }
    }
  }

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

  /// Drops the file and stops watching it. A cached copy stays on disk for
  /// the next open of the same version.
  void close(String hostPath) {
    _wanted.remove(hostPath);
    _again.remove(hostPath);
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
