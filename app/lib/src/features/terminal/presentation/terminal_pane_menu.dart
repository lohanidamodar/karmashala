// **The pane's right-click menu, and the two captures on it.** A `part`
// because `_TerminalPaneStackState` is private.

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
    // Read once as the menu is built. The captures are offered only for a
    // selection that caught something: a drag over blank cells is not a todo.
    final selected = selection == null
        ? null
        : terminalCopyText(session.terminal.buffer, selection);
    final capturable = selected != null && selected.trim().isNotEmpty;
    final notesEnabled = ref.read(notesEnabledProvider);
    final recordingThis = ref
        .read(terminalRecordingProvider)
        .isRecording(paneId);
    // What the recording will be able to become, said before it starts rather
    // than when the export dialog has to refuse.
    final canWriteMp4 = ref.read(videoSupportProvider).available;
    final choice = await showMenu<String>(
      context: context,
      // The same one-pixel anchor `ContextMenuRegion._show` uses, so a pane's
      // menu lands where the Explorer's does.
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: terminalPaneMenuItems(
        hasSelection: hasSelection,
        capturable: capturable,
        notesEnabled: notesEnabled,
        recording: recordingThis,
        canWriteMp4: canWriteMp4,
        inSplit: _sessions.isPaneInSplit(paneId),
      ),
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
        // The same rule as the chord, from the same place: a Paste that
        // silently does nothing with a screenshot on the clipboard is the bug.
        await pasteIntoTerminal(
          session.terminal,
          controller: session.controller,
          keyToProgram: imagePasteKeyFor(ref, session),
        );
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

  /// Keeps [selected] as a todo, filed under the pane's project. Collapsed to
  /// one line **and shown collapsed**, because that is what a todo is and a
  /// terminal selection usually is not — see [todoLineFrom].
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

  /// Confirmation, not navigation: a right-click in a terminal is not a request
  /// to rearrange the window.
  void _say(String message) => ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(message)));
}

/// A terminal pane's right-click menu, as values the caller switches on. Pure,
/// so which entries appear for which pane is testable without a pane.
List<PopupMenuEntry<String>> terminalPaneMenuItems({
  required bool hasSelection,
  required bool capturable,
  required bool notesEnabled,
  required bool recording,
  required bool canWriteMp4,
  required bool inSplit,
}) => [
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
  // Offered only with a selection, because unlike Copy there is no disabled
  // version that says anything: "create a todo from nothing" is not an act.
  if (capturable) ...[
    const DesktopMenuDivider(),
    DesktopMenuItem(
      value: 'todo',
      label: 'Create todo from selection',
      icon: AppIcons.listChecks,
    ),
    // Absent, not disabled, when Notes is off, so the affordance and the
    // surface cannot disagree about whether the user asked for it.
    if (notesEnabled)
      DesktopMenuItem(
        value: 'note',
        label: 'Create note from selection',
        icon: AppIcons.notePencil,
      ),
  ],
  const DesktopMenuDivider(),
  // The pane splits below are the only place *pane* splitting is offered: the
  // toolbar's buttons divide the whole workspace group, which is a different
  // act. Recording is a pane's own verb for the same reason.
  DesktopMenuItem(
    value: 'record',
    label: recording
        ? 'Stop recording'
        : canWriteMp4
        ? 'Record this pane'
        : 'Record this pane — GIF only, no MP4 here',
    icon: recording ? AppIcons.stopCircle : AppIcons.circle,
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
  // Only while there is a split to collapse: with one pane the tab strip's
  // close button is the way, and two words for one act in two places is how a
  // menu stops being read.
  if (inSplit) ...[
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
];
