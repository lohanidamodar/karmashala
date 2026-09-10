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
    // Built **only while its tab is on screen**: [MountedTabs] keeping a few
    // tabs mounted is right for a terminal and wrong for a settings page, which
    // would hold a subscription to everything its section reads. The page it
    // was on lives in `settingsTabSectionProvider`, so this is not a reset.
    if (isSettingsPane(paneId)) {
      return showing ? const SettingsTabView() : const SizedBox.shrink();
    }
    final instance = _sessions.instanceFor(paneId);
    // No instance is the `isEmptySlot` invariant and the only way this can be
    // null, so it is the empty state rather than nothing.
    if (instance == null) {
      return EmptyPaneRegion(
        paneId: paneId,
        focused: focused,
        onNewTerminal: () => _actions.openInSlot(paneId),
        onNewSession: () => NewSessionDialog.show(
          context,
          targetPaneId: paneId,
        ),
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

    final paneWidget = GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapDown: (_) => _sessions.focusPane(paneId),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: showFocusRing
              ? Border.all(
                  color: focused
                      ? theme.colorScheme.primary
                      : Colors.transparent,
                )
              : null,
        ),
        child: Column(
          children: [
            // A pane with no process says so rather than presenting an old
            // prompt as live. Its own `Consumer`, so an exit rebuilds only it.
            Consumer(
              builder: (context, ref, _) {
                final liveness = ref.watch(
                  terminalPaneLivenessProvider(paneId),
                );
                if (liveness.isLive) return const SizedBox.shrink();
                // The pane's *current* instance: a restart replaces it, and a
                // bar quoting the released one would name the directory of the
                // session before last.
                final live =
                    ref.watch(terminalPaneInstanceProvider(paneId)) ?? instance;
                return PaneStatusBar(
                  liveness: liveness,
                  workingDirectory: live.workingDirectory,
                  resumes: shouldResumeRatherThanRestart(
                    liveness: liveness,
                    isAgentPane: live.agentLaunch != null,
                  ),
                  onStart: () => _actions.startOrResumePane(context, paneId),
                );
              },
            ),
            // Its own `Consumer` over one bool, which moves when a recording
            // starts or stops and never while somebody types. No elapsed clock
            // and no byte count: one needs a ticker, the other rebuilds per
            // chunk of output.
            Consumer(
              builder: (context, ref, _) {
                final recording = ref.watch(
                  terminalRecordingProvider.select((s) => s.isRecording(paneId)),
                );
                if (!recording) return const SizedBox.shrink();
                return PaneRecordingBanner(
                  onStop: () => _stopRecording(context, paneId),
                );
              },
            ),
            Expanded(
              // Watches which object is behind this pane: `startPane`'s swap
              // moves no tab, so the stack's own watch cannot see it.
              child: Consumer(
                builder: (context, ref, _) {
                  final live =
                      ref.watch(terminalPaneInstanceProvider(paneId)) ??
                      instance;
                  return TerminalPaneView(
                    // Starting a pane swaps its instance in place; without the
                    // key the element is reused with the disposed focus node.
                    key: ObjectKey(live),
                    instance: live,
                    focused: focused,
                    fontSize: fontSize,
                    terminalTheme: terminalThemeFor(theme, _importedPalette()),
                    chordOverrides: chordOverrides,
                    onKeyEvent: _actions.onPaneKey,
                    // Right-click → copy selection / paste / end the session.
                    onSecondaryTapDown: (position) =>
                        _terminalMenu(context, position, paneId, live),
                    linkActions: ref.read(terminalLinkActionsProvider),
                  );
                },
              ),
            ),
          ],
        ),
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
      child: paneWithActions,
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
