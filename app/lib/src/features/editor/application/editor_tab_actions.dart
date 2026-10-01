import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:riverpod/riverpod.dart';

import '../../terminal/application/terminal_sessions_controller.dart';
import '../domain/document_id.dart';
import '../domain/media_kind.dart';
import 'media_documents.dart';
import 'open_documents.dart';

/// Opening a file in a tab of its own, and finding the unsaved work a close
/// would take with it.
class EditorTabActions {
  EditorTabActions(this._ref);

  final Ref _ref;

  /// Opens [documentId] — a document id, of which this machine's host path is
  /// one — in an editor tab and starts reading it. The read is not awaited:
  /// the tab is up at once and fills in. [line] is 1-based.
  String open(String documentId, {int? line}) {
    final id = documentId;
    final tabId = _ref
        .read(terminalSessionsControllerProvider.notifier)
        .openEditorTab(id);
    // A media file is shown by the media viewer, never read as text.
    if (mediaKindOf(id) != null) {
      unawaited(_ref.read(mediaDocumentsProvider.notifier).open(id));
    } else {
      unawaited(_ref.read(openDocumentsProvider.notifier).open(id));
    }
    if (line != null) {
      _ref.read(editorRevealLineProvider.notifier).reveal(id, line);
    }
    return tabId;
  }

  /// Opens the file at [path], in whichever environment it is.
  String openAt(EnvironmentPath path, {int? line}) =>
      open(documentIdOf(path), line: line);

  /// The files with unsaved edits inside [tabIds], in tab order.
  List<String> unsavedIn(Iterable<String> tabIds) {
    final dirty = _ref.read(dirtyDocumentPathsProvider);
    if (dirty.isEmpty) return const [];
    final wanted = tabIds.toSet();
    return [
      for (final tab in _ref.read(terminalSessionsControllerProvider).tabs)
        if (wanted.contains(tab.id))
          for (final paneId in tab.layout.panes)
            if (editorPanePath(paneId) case final path?)
              if (dirty.contains(path)) path,
    ];
  }

  /// The files open in [tabIds]. Read **before** a close: once the tabs are
  /// gone there is nothing left to ask which files they held.
  List<String> pathsIn(Iterable<String> tabIds) {
    final wanted = tabIds.toSet();
    return [
      for (final tab in _ref.read(terminalSessionsControllerProvider).tabs)
        if (wanted.contains(tab.id))
          for (final paneId in tab.layout.panes) ?editorPanePath(paneId),
    ];
  }

  /// Drops those buffers, so reopening one of those files reads it from disk
  /// rather than restoring an edit nobody kept.
  void release(Iterable<String> paths) {
    final documents = _ref.read(openDocumentsProvider.notifier);
    final media = _ref.read(mediaDocumentsProvider.notifier);
    for (final path in paths) {
      if (mediaKindOf(path) != null) {
        media.close(path);
      } else {
        documents.close(path);
      }
    }
  }
}

final editorTabActionsProvider = Provider<EditorTabActions>(
  (ref) => EditorTabActions(ref),
);

/// The 1-based line each open file has been asked to show. Cleared by the view
/// once it has scrolled, so asking for the same line twice scrolls twice.
class EditorRevealLines extends Notifier<Map<String, int>> {
  @override
  Map<String, int> build() => const {};

  void reveal(String hostPath, int line) => state = {...state, hostPath: line};

  void clear(String hostPath) {
    if (!state.containsKey(hostPath)) return;
    state = {...state}..remove(hostPath);
  }
}

final editorRevealLineProvider =
    NotifierProvider<EditorRevealLines, Map<String, int>>(
      EditorRevealLines.new,
    );
