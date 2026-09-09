// **What one tab's split tree actually draws** — the region, and the pane
// inside it: the header where a region has something to say, and the four
// shapes a pane takes (a document, an empty slot of a split, a dormant one
// under its status bar, a live one under its recording banner).
//
// A part of `terminal_panel.dart` rather than a library of its own, for the
// reason every part of this file has: `_TerminalPaneStackState` is private,
// and an extension on it can only be written inside its own library. Making
// the state class public to move it would cost the tree golden this split is
// proved by.

part of 'terminal_panel.dart';

/// See the file comment: one region, and the pane it is showing.
extension _TerminalPaneRegions on _TerminalPaneStackState {
  /// One region: its header, and the one pane it is showing.
  ///
  /// **Only the front pane is built.** A region is a stack, and building the
  /// ones behind it would put their render objects, layouts and controllers on
  /// screen's budget for something nobody can see — the same eager-`IndexedStack`
  /// mistake [MountedTabs] exists to undo one level up. The instance behind a
  /// hidden pane is untouched, so bringing it forward costs a build and nothing
  /// else: its buffer, its scrollback and its process were never its widget's.
  ///
  /// **The header is skipped where it would say nothing.** One region holding
  /// one pane is already named by the workbench strip, and an empty region
  /// draws its own invitation with its own close button — 30px of chrome
  /// repeating either would be 30px taken from the terminal for nothing.
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
    // A document is one of the app's own surfaces in a tab, and it is built
    // **only while its tab is the one on screen**. [MountedTabs] keeps a
    // handful of tabs mounted so a switch is instant, which is right for a
    // terminal — its widgets are cheap and its buffer is not theirs — and
    // wrong for a settings page, which would sit behind another tab holding a
    // subscription to everything its section reads. Which page it is on lives
    // in `settingsTabSectionProvider`, so coming back is a rebuild rather than
    // a reset. Measured in `settings_tab_test.dart`.
    if (isSettingsPane(paneId)) {
      return showing ? const SettingsTabView() : const SizedBox.shrink();
    }
    final instance = _sessions.instanceFor(paneId);
    // A pane a layout holds and the controller has no instance for is an empty
    // region of a split — the invariant `isEmptySlot` states. It is the only
    // way this can be null, so it is the empty state rather than nothing.
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
            // A pane with no process behind it says so, rather than presenting
            // an old prompt as a live one. In its own `Consumer` so a process
            // exiting rebuilds this bar and nothing else.
            Consumer(
              builder: (context, ref, _) {
                final liveness = ref.watch(
                  terminalPaneLivenessProvider(paneId),
                );
                if (liveness.isLive) return const SizedBox.shrink();
                // The pane's *current* instance for the same reason the view
                // below takes one: a restart replaces it, and a bar quoting the
                // released one would name the directory of the session before
                // last if the new process also stopped.
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
            // A recording is a long-lived side effect, so it is on screen for
            // as long as it runs and can be stopped from where it is said. In
            // its own `Consumer` watching one bool, which moves when a
            // recording starts or stops and at no other time — never while
            // somebody types. It carries no elapsed clock and no byte count on
            // purpose: one would need a ticker and the other would rebuild per
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
              // In its own `Consumer`, watching *which object* is behind this
              // pane, for the same reason the status bar above has one: the
              // stack's own watch is the tab topology, and starting a pane
              // moves neither the tabs nor which one is in front. So the swap
              // `startPane` performs — release the instance, adopt a new one
              // with a new `Terminal`, `FocusNode` and `ScrollController` —
              // was invisible from up there, and the pane went on rendering
              // the instance that had just been disposed. See
              // [terminalPaneInstanceProvider] for what that looked like from
              // the focus node's side, and why the pane came back typable only
              // when something else happened to rebuild the stack.
              //
              // Falling back to [instance] rather than dropping the pane:
              // `_buildPane` has already established there is one, and the
              // provider can only disagree while a rebuild is in flight.
              child: Consumer(
                builder: (context, ref, _) {
                  final live =
                      ref.watch(terminalPaneInstanceProvider(paneId)) ??
                      instance;
                  return TerminalPaneView(
                    // Starting a pane swaps its instance in place; without a
                    // key the element would be reused and keep the disposed
                    // focus node.
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
  /// while there is none to move, when the offer would lead nowhere.
  bool _canMoveAPaneHere(String paneId) {
    final tabs = ref.read(terminalSessionsControllerProvider).tabs;
    return tabs.any(
      (tab) => tab.layout.panes.any(
        (candidate) => _sessions.canMovePaneIntoRegion(candidate, paneId),
      ),
    );
  }
}
