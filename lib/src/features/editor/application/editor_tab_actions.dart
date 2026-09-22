import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:riverpod/riverpod.dart';

import '../../terminal/application/terminal_sessions_controller.dart';
import '../domain/document_id.dart';
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
    final id = _idForOpen(documentId);
    final tabId = _ref
        .read(terminalSessionsControllerProvider.notifier)
        .openEditorTab(id);
    unawaited(_ref.read(openDocumentsProvider.notifier).open(id));
    if (line != null) {
      _ref.read(editorRevealLineProvider.notifier).reveal(id, line);
    }
    return tabId;
  }

  /// Opens the file at [path], in whichever environment it is.
  String openAt(EnvironmentPath path, {int? line}) =>
      open(documentIdOf(path), line: line);

  /// The id a tab already showing the same file uses — one restored from
  /// before ids named their environment keeps its `\\wsl.localhost` spelling —
  /// or else the canonical one, so the same file never opens twice.
  String _idForOpen(String documentId) {
    final canonical = canonicalDocumentId(documentId);
    for (final tab in _ref.read(terminalSessionsControllerProvider).tabs) {
      for (final paneId in tab.layout.panes) {
        final open = editorPanePath(paneId);
        if (open != null && canonicalDocumentId(open) == canonical) {
          return open;
        }
      }
    }
    return canonical;
  }

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
    for (final path in paths) {
      documents.close(path);
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
