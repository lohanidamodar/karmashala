import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../notifications/application/notification_providers.dart';
import '../data/document_store.dart';
import '../domain/source_document.dart';
import 'document_sources.dart';

final documentStoreProvider = Provider<DocumentStore>(
  (ref) => DocumentStore(sources: ref.watch(documentSourcesProvider)),
);

enum SaveResult { saved, unchanged, stale, failed }

class SaveOutcome {
  const SaveOutcome(this.result, [this.message]);

  final SaveResult result;
  final String? message;

  /// Whether the file on disk now holds the buffer — nothing was lost.
  bool get ok => result == SaveResult.saved || result == SaveResult.unchanged;
}

/// Every open buffer, keyed by document id (`document_id.dart`) — a host path
/// for this machine's files. Absence means "not loaded yet".
/// A pane is built only while its tab is on screen, so the text cannot live
/// in widget state: switching tabs would drop every unsaved edit.
class OpenDocuments extends Notifier<Map<String, SourceDocument>> {
  final Set<String> _reading = <String>{};

  /// Paths with a disk check in flight. Over the WSL share a stat can take
  /// seconds, and a poll must not stack a second one behind it.
  final Set<String> _checking = <String>{};

  /// Paths with a save's write in flight: a check that stats mid-write would
  /// call our own save somebody else's change.
  final Set<String> _writing = <String>{};

  @override
  Map<String, SourceDocument> build() {
    ref.listen(windowFocusedProvider, (previous, focused) {
      // A genuine return to the app — the first `true` at startup is not one.
      if (focused && previous == false) unawaited(checkAllOnDisk());
    });
    return const {};
  }

  /// The files a tab still wants. A read or a write started before a close
  /// must not put its result back afterwards — the buffer would outlive every
  /// tab holding it and be served to whoever opened that file next.
  final Set<String> _wanted = {};

  bool _stillWanted(String hostPath) => _wanted.contains(hostPath);

  /// Reads [hostPath] from disk unless it is already open. Idempotent: a
  /// restored tab and an explicit open both call it.
  Future<void> open(String hostPath) async {
    _wanted.add(hostPath);
    if (state.containsKey(hostPath) || !_reading.add(hostPath)) return;
    try {
      final document = await ref.read(documentStoreProvider).load(hostPath);
      if (state.containsKey(hostPath) || !_stillWanted(hostPath)) return;
      state = {...state, hostPath: document};
    } on Object catch (error) {
      // `load` classifies rather than throws, bar an environment that did not
      // answer — and an escaped error leaves the pane on a spinner for ever
      // (§5). A refusal keeps no stamp, so the next check that reaches the
      // file reads it.
      if (!_stillWanted(hostPath)) return;
      state = {
        ...state,
        hostPath: SourceDocument(
          hostPath: hostPath,
          text: '',
          savedText: '',
          refusal: DocumentRefusal.unreadable,
          error: error is DocumentUnreachableException
              ? error.message
              : 'Could not read this file: $error',
        ),
      };
    } finally {
      _reading.remove(hostPath);
    }
  }

  void edit(String hostPath, String text) {
    final document = state[hostPath];
    if (document == null || !document.isEditable) return;
    if (document.text == text) return;
    state = {...state, hostPath: document.withText(text)};
  }

  /// Writes the buffer back. Refuses with [SaveResult.stale] when the file
  /// changed under us, unless [force].
  Future<SaveOutcome> save(String hostPath, {bool force = false}) async {
    var document = state[hostPath];
    if (document == null) {
      return const SaveOutcome(SaveResult.failed, 'That file is not open.');
    }
    if (!document.isReadable) {
      return SaveOutcome(SaveResult.failed, document.error);
    }
    if (!document.isEditable) {
      return SaveOutcome(
        SaveResult.failed,
        '${document.name} was opened read-only because of its size.',
      );
    }
    if (!document.isReachable) {
      return SaveOutcome(SaveResult.failed, _heldMessage(document));
    }
    final store = ref.read(documentStoreProvider);
    var expect = const WriteExpectation.any();
    if (!force) {
      final FileStamp? onDisk;
      try {
        onDisk = await store.stamp(hostPath);
      } on DocumentUnreachableException catch (error) {
        _noteUnreachable(hostPath, error.message);
        return SaveOutcome(SaveResult.failed, _heldMessage(document, error));
      }
      // What this check saw is what the write must still find: the gap
      // between the two is the source's to close, not a stat's.
      expect = onDisk == null
          ? const WriteExpectation.absent()
          : WriteExpectation.version(onDisk);
      // A deletion the tab already shows is the reader's to undo: saving puts
      // the file back rather than asking again.
      final shownDeleted = document.disk == DiskState.deleted;
      if (onDisk == null) {
        if (document.stamp != null && !shownDeleted) {
          _noteStale(hostPath, onDisk);
          // Gone is not changed, and the difference decides what "reload"
          // would do to the buffer (§19).
          return SaveOutcome(
            SaveResult.stale,
            '${document.name} is no longer on disk.',
          );
        }
      } else if (shownDeleted || !(document.stamp?.matches(onDisk) ?? true)) {
        _noteStale(hostPath, onDisk);
        return SaveOutcome(
          SaveResult.stale,
          '${document.name} changed on disk since it was opened.',
        );
      }
      document = state[hostPath] ?? document;
    }
    if (document.text == document.savedText &&
        document.disk != DiskState.deleted) {
      return const SaveOutcome(SaveResult.unchanged);
    }
    final FileStamp stamp;
    _writing.add(hostPath);
    try {
      stamp = await store.write(hostPath, document.diskText, expect: expect);
    } on DocumentStaleException catch (error) {
      _noteStale(hostPath, error.current);
      return SaveOutcome(
        SaveResult.stale,
        error.current == null
            ? '${document.name} is no longer on disk.'
            : '${document.name} changed on disk since it was opened.',
      );
    } on DocumentUnreachableException catch (error) {
      _noteUnreachable(hostPath, error.message);
      return SaveOutcome(SaveResult.failed, _heldMessage(document, error));
    } on DocumentWriteException catch (error) {
      // The buffer stays dirty: the dot clears only on a write that returned.
      return SaveOutcome(SaveResult.failed, error.message);
    } finally {
      _writing.remove(hostPath);
    }
    var saved = document.asSaved(stamp);
    final typedMeanwhile = state[hostPath]?.text;
    if (typedMeanwhile != null && typedMeanwhile != document.text) {
      saved = saved.withText(typedMeanwhile);
    }
    if (_stillWanted(hostPath)) state = {...state, hostPath: saved};
    return const SaveOutcome(SaveResult.saved);
  }

  /// Re-reads from disk, discarding the buffer.
  Future<void> reload(String hostPath) async {
    final SourceDocument document;
    try {
      document = await ref.read(documentStoreProvider).load(hostPath);
    } on DocumentUnreachableException catch (error) {
      // Discarding the buffer for bytes nobody could read would lose both.
      _noteUnreachable(hostPath, error.message);
      return;
    }
    if (!_stillWanted(hostPath)) return;
    state = {...state, hostPath: document};
  }

  /// The environment did not answer: the buffer says so and keeps its text.
  void _noteUnreachable(String hostPath, String reason) {
    final now = state[hostPath];
    if (now == null || !_stillWanted(hostPath)) return;
    if (now.unreachable == reason) return;
    _put(hostPath, now.markedUnreachable(reason));
  }

  String _heldMessage(
    SourceDocument document, [
    DocumentUnreachableException? error,
  ]) =>
      '${error?.message ?? document.unreachable ?? 'The connection was lost'}. '
      '${document.name} was not saved; your edits are kept until it '
      'reconnects.';

  /// "Keep mine" on a change the bar reported: the buffer stays, and the next
  /// save overwrites that change without asking again.
  void keepMine(String hostPath) {
    final document = state[hostPath];
    if (document == null || document.disk != DiskState.changed) return;
    _put(hostPath, document.keepingMine());
  }

  /// Checks every open buffer against the disk — the window came back, and
  /// anything could have happened while it was away.
  Future<void> checkAllOnDisk() =>
      Future.wait([for (final path in state.keys) checkOnDisk(path)]);

  /// Stats [hostPath] and brings the buffer in line with what it finds: a clean
  /// buffer is re-read, a dirty one is marked [DiskState.changed] and keeps
  /// its text, a vanished file is marked [DiskState.deleted]. One check per
  /// path at a time; one asked for while another runs is dropped, since the
  /// running one answers it. Never throws.
  Future<void> checkOnDisk(String hostPath) async {
    if (!state.containsKey(hostPath) || !_stillWanted(hostPath)) return;
    if (_writing.contains(hostPath) || _reading.contains(hostPath)) return;
    if (!_checking.add(hostPath)) return;
    try {
      final FileStamp? onDisk;
      try {
        onDisk = await ref.read(documentStoreProvider).stamp(hostPath);
      } on DocumentUnreachableException catch (error) {
        if (ref.mounted) _noteUnreachable(hostPath, error.message);
        return;
      } on Object {
        // A share that did not answer is not evidence the file changed.
        return;
      }
      if (!ref.mounted || !_stillWanted(hostPath)) return;
      if (_writing.contains(hostPath)) return;
      var document = state[hostPath];
      if (document == null) return;
      if (!document.isReachable) {
        document = document.markedReachable();
        _put(hostPath, document);
      }
      if (_sameFile(document.knownDiskStamp, onDisk)) return;
      if (!document.isReadable) {
        // Nothing can be typed into a refused file, so re-reading loses
        // nothing — and "binary" may well be text again.
        await _takeFromDisk(hostPath, document);
      } else if (onDisk == null) {
        _put(hostPath, document.markedDeleted());
      } else if (document.stamp?.matches(onDisk) ?? false) {
        _put(hostPath, document.markedCurrent());
      } else if (document.isDirty) {
        _put(hostPath, document.markedChanged(onDisk));
      } else {
        await _takeFromDisk(hostPath, document);
      }
    } finally {
      _checking.remove(hostPath);
    }
  }

  static bool _sameFile(FileStamp? known, FileStamp? onDisk) =>
      known == null ? onDisk == null : known.matches(onDisk);

  void _put(String hostPath, SourceDocument document) {
    state = {...state, hostPath: document};
  }

  /// A refused save saw the disk before any check did: the buffer says so as a
  /// check would have, so the bar shows whether or not a dialog also asks.
  void _noteStale(String hostPath, FileStamp? onDisk) {
    final now = state[hostPath];
    if (now == null || !now.isReadable || !_stillWanted(hostPath)) return;
    if (_sameFile(now.knownDiskStamp, onDisk)) return;
    _put(
      hostPath,
      onDisk == null ? now.markedDeleted() : now.markedChanged(onDisk),
    );
  }

  /// Replaces a clean buffer with the file's current bytes, unless it was typed
  /// into while they were read — then the typing wins and the change is shown.
  Future<void> _takeFromDisk(String hostPath, SourceDocument seen) async {
    final SourceDocument loaded;
    try {
      loaded = await ref.read(documentStoreProvider).load(hostPath);
    } on DocumentUnreachableException catch (error) {
      if (ref.mounted) _noteUnreachable(hostPath, error.message);
      return;
    } on Object {
      return;
    }
    if (!ref.mounted || !_stillWanted(hostPath)) return;
    final now = state[hostPath];
    if (now == null) return;
    final gone = loaded.refusal == DocumentRefusal.notFound;
    if (now.text != seen.text) {
      final onDisk = loaded.stamp;
      if (gone) {
        _put(hostPath, now.markedDeleted());
      } else if (onDisk != null) {
        _put(hostPath, now.markedChanged(onDisk));
      }
      return;
    }
    if (now.isReadable && gone) {
      // Gone between the stat and the read: the text stays, as for any delete.
      _put(hostPath, now.markedDeleted());
      return;
    }
    _put(hostPath, loaded);
  }

  /// Drops the buffer. Unsaved text is gone — the caller asks first.
  void close(String hostPath) {
    _wanted.remove(hostPath);
    if (!state.containsKey(hostPath)) return;
    state = {...state}..remove(hostPath);
  }

  bool isDirty(String hostPath) => state[hostPath]?.isDirty ?? false;
}

final openDocumentsProvider =
    NotifierProvider<OpenDocuments, Map<String, SourceDocument>>(
      OpenDocuments.new,
    );

/// One buffer, or null while it is still being read.
final openDocumentProvider = Provider.family<SourceDocument?, String>(
  (ref, hostPath) =>
      ref.watch(openDocumentsProvider.select((open) => open[hostPath])),
);

/// Host paths with unsaved edits — what a tab chip's dot is drawn from.
final dirtyDocumentPathsProvider = Provider<Set<String>>((ref) {
  final open = ref.watch(openDocumentsProvider);
  return {
    for (final entry in open.entries)
      if (entry.value.isDirty) entry.key,
  };
});
