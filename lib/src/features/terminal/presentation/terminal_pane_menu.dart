// **The pane's right-click menu, and the two things it keeps** — copy, paste,
// find, record, the pane splits, the way back out of one, and ending the
// session; plus the two capture rows, which are the terminal's door into the
// Todos and Notes an agent already reaches through `todo_add` and `note_add`.
//
// A part of `terminal_panel.dart` rather than a library of its own, for the
// reason every part of this file has: `_TerminalPaneStackState` is private,
// and an extension on it can only be written inside its own library. Making
// the state class public to move it would cost the tree golden this split is
// proved by.

part of 'terminal_panel.dart';

/// See the file comment: the pane menu, and the two captures on it.
extension _TerminalPaneMenu on _TerminalPaneStackState {
  /// Ends the recording on [paneId] and offers what can be made from it.
  Future<void> _stopRecording(BuildContext context, String paneId) async {
    await ref.read(terminalRecordingProvider.notifier).stop(paneId);
    if (context.mounted) await showRecordingSavedDialog(context);
  }

  Future<void> _terminalMenu(
    BuildContext context,
    Offset position,
    String paneId,
    TerminalInstance session,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final selection = session.controller.selection;
    final hasSelection = selection != null;
    // Read once, as the menu is built, and used by every row that wants it.
    // The two capture rows are only offered for a selection that caught
    // something: a drag over blank cells is not a todo, and a row that opens
    // an empty composer is a row that wasted the click.
    final selected = selection == null
        ? null
        : session.terminal.buffer.getText(selection);
    final capturable = selected != null && selected.trim().isNotEmpty;
    final notesEnabled = ref.read(notesEnabledProvider);
    final recordingThis = ref.read(terminalRecordingProvider).isRecording(paneId);
    // What the recording will be able to become, said before it is started
    // rather than when the export dialog has to refuse.
    final canWriteMp4 = ref.read(videoSupportProvider).available;
    final choice = await showMenu<String>(
      context: context,
      // The same one-pixel anchor `ContextMenuRegion._show` uses, so a menu
      // opened from a pane lands where one opened from the Explorer does.
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        DesktopMenuItem(
          value: 'copy',
          label: 'Copy',
          icon: AppIcons.copy,
          shortcut: shellChordLabel<CopySelectionTextIntent>(),
          enabled: hasSelection,
        ),
        DesktopMenuItem(
          value: 'paste',
          label: 'Paste',
          icon: AppIcons.clipboardText,
          shortcut: shellChordLabel<TerminalPasteIntent>(),
        ),
        DesktopMenuItem(
          value: 'find',
          label: 'Find…',
          icon: AppIcons.magnifyingGlass,
          shortcut: shellChordLabel<FindInScrollbackIntent>(),
        ),
        // Keeping what is on screen, in the two places the app already keeps
        // the user's own writing — and the two an agent already reaches through
        // `todo_add` and `note_add`. Offered only with a selection, because
        // unlike Copy there is no disabled version of this that says anything:
        // "create a todo from nothing" is not a lesser act, it is not an act.
        if (capturable) ...[
          const DesktopMenuDivider(),
          DesktopMenuItem(
            value: 'todo',
            label: 'Create todo from selection',
            icon: AppIcons.listChecks,
          ),
          // Absent, not disabled, when Notes is switched off — the one reading
          // `notesEnabledProvider` exists for, so the capture affordance and
          // the surface cannot disagree about whether the user asked for this.
          if (notesEnabled)
            DesktopMenuItem(
              value: 'note',
              label: 'Create note from selection',
              icon: AppIcons.notePencil,
            ),
        ],
        const DesktopMenuDivider(),
        // The *pane* split, and the only place it is offered. The toolbar's two
        // split buttons divide the whole workspace group now — a strip, a
        // surface and a status bar of its own — which is a different act, and
        // one row of chrome cannot honestly stand for both.
        // Recording is a pane's own verb, on the pane's own menu, beside the
        // other one — the same placement rule the split rows below state.
        DesktopMenuItem(
          value: 'record',
          label: recordingThis
              ? 'Stop recording'
              : canWriteMp4
              ? 'Record this pane'
              : 'Record this pane — GIF only, no MP4 here',
          icon: recordingThis ? AppIcons.stopCircle : AppIcons.circle,
        ),
        const DesktopMenuDivider(),
        DesktopMenuItem(
          value: 'split-pane-right',
          label: 'Split pane right',
          icon: AppIcons.squareSplitHorizontal,
        ),
        DesktopMenuItem(
          value: 'split-pane-down',
          label: 'Split pane down',
          icon: AppIcons.squareSplitVertical,
        ),
        const DesktopMenuDivider(),
        // Only while there is a split to collapse, and only then: with one
        // pane the tab strip's own close button is the way, and two words for
        // one act in two places is how a menu stops being read.
        if (_sessions.isPaneInSplit(paneId)) ...[
          // The way back out of a split, beside the way to close one. The
          // region this pane leaves goes with it — see [movePaneToNewTab].
          DesktopMenuItem(
            value: 'untangle',
            label: 'Move pane to a new tab',
            icon: AppIcons.terminalWindow,
          ),
          DesktopMenuItem(
            value: 'close',
            label: 'Close pane',
            icon: AppIcons.x,
            shortcut: shellChordLabel<CloseTerminalTabIntent>(),
          ),
          const DesktopMenuDivider(),
        ],
        // Closing the tab only detaches; this is how a session actually ends.
        DesktopMenuItem(
          value: 'end',
          label: 'End session',
          icon: AppIcons.power,
          destructive: true,
        ),
      ],
    );
    switch (choice) {
      case 'record':
        if (recordingThis) {
          if (context.mounted) await _stopRecording(context, paneId);
        } else {
          ref.read(terminalRecordingProvider.notifier).start(paneId);
        }
      case 'copy':
        if (selected != null) {
          await Clipboard.setData(ClipboardData(text: selected));
        }
      case 'todo':
        if (selected != null) await _captureTodo(paneId, selected);
      case 'note':
        if (selected != null) await _captureNote(paneId, selected);
      case 'paste':
        // The same rule as the chord, from the same place: a menu item called
        // Paste that silently does nothing with a screenshot on the clipboard
        // is the bug being fixed, not a lesser version of it.
        await pasteIntoTerminal(session.terminal, controller: session.controller);
      case 'find':
        _actions.openSearch();
      case 'split-pane-right':
        _actions.splitPane(SplitAxis.horizontal);
      case 'split-pane-down':
        _actions.splitPane(SplitAxis.vertical);
      case 'untangle':
        _sessions.movePaneToNewTab(paneId);
      case 'close':
        _sessions.closePane(paneId);
      case 'end':
        _sessions.endSession(paneId);
    }
  }

  /// Keeps [selected] as a todo, filed under the pane's project.
  ///
  /// Collapsed to one line **and shown collapsed**, because that is what a
  /// todo is and a terminal selection usually is not — see [todoLineFrom].
  Future<void> _captureTodo(String paneId, String selected) async {
    final source = ref.read(terminalSelectionSourceProvider(paneId));
    final todo = await showNewTodoDialog(
      context,
      ref,
      body: todoLineFrom(selected),
      projectId: source.projectId,
      joinedLines: selectionLineCount(selected),
    );
    if (todo == null || !mounted) return;
    _say('Added to Todos.');
  }

  /// Keeps [selected] as a note, word for word, remembering the session and
  /// repository it was taken from. Nothing is filled in for a plain shell.
  Future<void> _captureNote(String paneId, String selected) async {
    final source = ref.read(terminalSelectionSourceProvider(paneId));
    final note = await showCapturedNoteDialog(
      context,
      ref,
      body: selected,
      projectId: source.projectId,
      sourceSessionId: source.sessionId,
      sourceRepositoryId: source.repositoryId,
    );
    if (note == null || !mounted) return;
    _say('Saved to Notes.');
  }

  /// Confirmation, not navigation: the side panel stays where the user left
  /// it. A right-click in a terminal is not a request to rearrange the window.
  void _say(String message) => ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(message)));
}
