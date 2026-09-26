// **What one tab's split tree draws** — the region, and the four shapes a pane
// takes. A `part` because `_TerminalPaneStackState` is private.

part of 'terminal_panel.dart';

/// See the file comment: one region, and the pane it is showing.
extension _TerminalPaneRegions on _TerminalPaneStackState {
  /// One region: its header, and the one pane it is showing. **Only the front
  /// pane is built**, and the header is skipped where it would say nothing.
  Widget _buildRegion(
    PaneGroup group,
    TerminalTab tab,
    bool tabActive, {
    required bool showing,
  }) {
    final split = tab.layout.groups.length > 1;
    final empty =
        group.panes.length == 1 &&
        _sessions.instanceFor(group.activePaneId) == null;
    final pane = _buildPane(
      group.activePaneId,
      showing: showing,
      focused: tabActive && group.activePaneId == tab.focusedPaneId,
      showFocusRing: split,
    );
    if (empty || group.panes.length < 2) return pane;
    return Column(
      children: [
        PaneGroupStrip(
          group: group,
          focused: tabActive && group.panes.contains(tab.focusedPaneId),
        ),
        Expanded(child: pane),
      ],
    );
  }

  Widget _buildPane(
    String paneId, {
    required bool focused,
    required bool showFocusRing,
    required bool showing,
  }) {
    final theme = Theme.of(context);
    // Built **only while its tab is on screen**: a settings page kept mounted
    // would hold a subscription to everything its section reads.
    if (isSettingsPane(paneId)) {
      return showing ? const SettingsTabView() : const SizedBox.shrink();
    }
    // No `showing` gate: the stack keeps every mounted tab alive, and an
    // editor rebuilt on every switch would lose the caret and the scroll. It is
    // told `showing` only so the painted one alone polls its file.
    // Keyed by the file: two editor panes can share one region, and without a
    // key the State of the one leaving is handed the other's path.
    if (editorPanePath(paneId) case final path?) {
      return EditorTabView(
        key: ValueKey(paneId),
        hostPath: path,
        showing: showing,
      );
    }
    if (notePaneNoteId(paneId) case final noteId?) {
      return NoteTabView(key: ValueKey(paneId), noteId: noteId);
    }
    if (diffTargetOf(paneId) case final target?) {
      return DiffTabView(key: ValueKey(paneId), target: target);
    }
    // Keyed by the pane, as the editor is: two browsers can share a region,
    // and without a key the one leaving hands the other its two machines.
    if (isFilesPane(paneId)) {
      return FilesTabView(key: ValueKey(paneId), paneId: paneId);
    }
    // A document id we cannot read is still a document: saying so beats
    // drawing the empty-terminal slot the instance lookup below would.
    if (isDocumentPane(paneId)) {
      return const PanePlaceholder(
        message: 'This tab names a document Karmashala cannot read.',
        icon: AppIcons.warningCircle,
      );
    }
    final instance = _sessions.instanceFor(paneId);
    // No instance is the `isEmptySlot` invariant and the only way this can be
    // null, so it is the empty state rather than nothing.
    if (instance == null) {
      return EmptyPaneRegion(
        paneId: paneId,
        focused: focused,
        onNewTerminal: () => _actions.openInSlot(paneId),
        onNewSession: () =>
            NewSessionDialog.show(context, targetPaneId: paneId),
        onClose: () => _sessions.closePane(paneId),
        onMoveTabHere: _canMoveAPaneHere(paneId)
            ? () => TabPicker.show(
                context,
                (ref) => panesMovableInto(ref, paneId),
              )
            : null,
      );
    }
    final fontSize = ref.watch(
      settingsControllerProvider.select((s) => s.terminalFontSize),
    );
    final chordOverrides = ref.watch(
      settingsControllerProvider.select((s) => s.terminalChordOverrides),
    );

    final paneWidget = PaneFrame(
      focused: focused,
      showFocusRing: showFocusRing,
      onTapDown: () => _sessions.focusPane(paneId),
      child: Column(
        children: [
          PaneLivenessBar(
            paneId: paneId,
            fallback: instance,
            onStart: () => _actions.startOrResumePane(context, paneId),
          ),
          PaneRecordingBar(
            paneId: paneId,
            onStop: () => _stopRecording(context, paneId),
          ),
          Expanded(
            child: LiveTerminalPane(
              paneId: paneId,
              fallback: instance,
              focused: focused,
              fontSize: fontSize,
              terminalTheme: terminalThemeFor(theme, _importedPalette()),
              chordOverrides: chordOverrides,
              onKeyEvent: _actions.onPaneKey,
              // Right-click → copy selection / paste / end the session.
              onSecondaryTapDown: (position, live) =>
                  _terminalMenu(context, position, paneId, live),
            ),
          ),
        ],
      ),
    );

    final paneWithActions = Stack(
      children: [
        Positioned.fill(child: paneWidget),
        if (showFocusRing)
          Positioned(
            top: Insets.xs,
            right: Insets.xs,
            child: _PaneFloatingActions(
              paneId: paneId,
              focused: focused,
              onMoveToNewTab: () => _sessions.movePaneToNewTab(paneId),
              onClose: () => _sessions.closePane(paneId),
            ),
          ),
      ],
    );

    return _PaneDropTarget(
      paneId: paneId,
      groupId: widget.groupId,
      child: TerminalFileDrop(paneId: paneId, child: paneWithActions),
    );
  }

  /// Whether any pane could be moved into the empty region [paneId] — false
  /// when the offer would lead nowhere.
  bool _canMoveAPaneHere(String paneId) {
    final tabs = ref.read(terminalSessionsControllerProvider).tabs;
    return tabs.any(
      (tab) => tab.layout.panes.any(
        (candidate) => _sessions.canMovePaneIntoRegion(candidate, paneId),
      ),
    );
  }
}
