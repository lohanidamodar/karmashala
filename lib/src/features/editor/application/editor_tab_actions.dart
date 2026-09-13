import 'dart:async';

import 'package:karmashala_terminal_core/geometry.dart';
import 'package:riverpod/riverpod.dart';

import '../../terminal/application/terminal_sessions_controller.dart';
import 'open_documents.dart';

/// Opening a file in a tab of its own, and finding the unsaved work a close
/// would take with it.
class EditorTabActions {
  EditorTabActions(this._ref);

  final Ref _ref;

  /// Opens [hostPath] in an editor tab and starts reading it. The read is not
  /// awaited — the tab is up at once and fills in. [line] is 1-based.
  String open(String hostPath, {int? line}) {
    final tabId = _ref
        .read(terminalSessionsControllerProvider.notifier)
        .openEditorTab(hostPath);
    unawaited(_ref.read(openDocumentsProvider.notifier).open(hostPath));
    if (line != null) {
      _ref.read(editorRevealLineProvider.notifier).reveal(hostPath, line);
    }
    return tabId;
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
