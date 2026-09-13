import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/document_store.dart';
import '../domain/source_document.dart';

final documentStoreProvider = Provider<DocumentStore>(
  (ref) => const DocumentStore(),
);

enum SaveResult { saved, unchanged, stale, failed }

class SaveOutcome {
  const SaveOutcome(this.result, [this.message]);

  final SaveResult result;
  final String? message;

  /// Whether the file on disk now holds the buffer — nothing was lost.
  bool get ok => result == SaveResult.saved || result == SaveResult.unchanged;
}

/// Every open buffer, keyed by host path. Absence means "not loaded yet".
/// A pane is built only while its tab is on screen, so the text cannot live
/// in widget state: switching tabs would drop every unsaved edit.
class OpenDocuments extends Notifier<Map<String, SourceDocument>> {
  final Set<String> _reading = <String>{};

  @override
  Map<String, SourceDocument> build() => const {};

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
      // `load` classifies rather than throws, so this is a contract break — but
      // an escaped error here leaves the pane on a spinner for ever (§5).
      if (!_stillWanted(hostPath)) return;
      state = {
        ...state,
        hostPath: SourceDocument(
          hostPath: hostPath,
          text: '',
          savedText: '',
          refusal: DocumentRefusal.unreadable,
          error: 'Could not read this file: $error',
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
    final store = ref.read(documentStoreProvider);
    if (!force) {
      final onDisk = await store.stamp(hostPath);
      if (document.stamp != null && onDisk == null) {
        // Gone is not changed, and the difference decides what "reload" would
        // do to the buffer (§19).
        return SaveOutcome(
          SaveResult.stale,
          '${document.name} is no longer on disk.',
        );
      }
      if (!(document.stamp?.matches(onDisk) ?? true)) {
        return SaveOutcome(
          SaveResult.stale,
          '${document.name} changed on disk since it was opened.',
        );
      }
      document = state[hostPath] ?? document;
    }
    if (document.text == document.savedText) {
      return const SaveOutcome(SaveResult.unchanged);
    }
    final FileStamp stamp;
    try {
      stamp = await store.write(hostPath, document.diskText);
    } on DocumentWriteException catch (error) {
      // The buffer stays dirty: the dot clears only on a write that returned.
      return SaveOutcome(SaveResult.failed, error.message);
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
    final document = await ref.read(documentStoreProvider).load(hostPath);
    if (!_stillWanted(hostPath)) return;
    state = {...state, hostPath: document};
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
