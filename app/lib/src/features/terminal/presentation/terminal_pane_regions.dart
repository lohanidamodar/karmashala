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

  /// One pane, and the split target a dragged tab or pane is dropped on. A
  /// terminal's body carries its own (inside its file drop); every document —
  /// a device's live preview, an editor, a note — gets the same one here, so
  /// any tab splits beside any other (owner, 2026-10-01).
  Widget _buildPane(
    String paneId, {
    required bool focused,
    required bool showFocusRing,
    required bool showing,
  }) {
    final body = _buildPaneBody(
      paneId,
      focused: focused,
      showFocusRing: showFocusRing,
      showing: showing,
    );
    if (!isDocumentPane(paneId)) return body;
    return _PaneDropTarget(
      paneId: paneId,
      groupId: widget.groupId,
      child: _DocumentPaneFocus(focused: focused && showing, child: body),
    );
  }

  Widget _buildPaneBody(
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
    // The same gate: the Usage page reads every recent session's own file
    // and the account history, which nobody should pay for off screen.
    if (isUsagePane(paneId)) {
      return showing ? const UsageTabView() : const SizedBox.shrink();
    }
    // The same gate: off screen it would hold the dashboard for nobody.
    if (isStoresPane(paneId)) {
      return showing ? const StoresTabView() : const SizedBox.shrink();
    }
    // The same gate: off screen its timers would repaint for nobody.
    if (isLogsPane(paneId)) {
      return showing ? const LogsTabView() : const SizedBox.shrink();
    }
    // The same gate: off screen it would keep the whole workspace in view for
    // nobody.
    if (isOverviewPane(paneId)) {
      return showing ? const OverviewTabView() : const SizedBox.shrink();
    }
    // The same gate, and it is what stops the reading: off screen nothing
    // asks the server what runs.
    if (isRunningPane(paneId)) {
      return showing ? const RunningTabView() : const SizedBox.shrink();
    }
    // The same gate: off screen its clocks would tick for nobody.
    if (isAutomationsPane(paneId)) {
      return showing ? const WorkflowsTabView() : const SizedBox.shrink();
    }
    // The same gate: a device pane off screen would keep its live view and its
    // polling of adb going for nobody. A layout restored from a desktop onto a
    // client with no Devices area draws nothing there.
    if (isDevicePane(paneId)) {
      return showing && ref.read(capabilitiesProvider).devicesArea
          ? const DevicePane()
          : const SizedBox.shrink();
    }
    // One device's live preview. The same gate, and it is what pauses the
    // picture: off screen the session is torn down, and coming back resumes
    // it. Keyed by the pane: two previews can share a region.
    if (devicePreviewSerial(paneId) case final serial?) {
      return showing && ref.read(capabilitiesProvider).devicesArea
          ? DevicePane.preview(
              key: ValueKey(paneId),
              serial: serial,
              focused: focused,
            )
          : const SizedBox.shrink();
    }
    // The same gate: off screen it would follow the attached page's state for
    // nobody. The controller outlives it, so coming back loses no connection.
    if (isBrowserPane(paneId)) {
      return showing ? const BrowserPane() : const SizedBox.shrink();
    }
    // No `showing` gate: the stack keeps every mounted tab alive, and an
    // editor rebuilt on every switch would lose the caret and the scroll. Its
    // file is watched by the server, so no editor polls.
    // Keyed by the file: two editor panes can share one region, and without a
    // key the State of the one leaving is handed the other's path.
    if (editorPanePath(paneId) case final path?) {
      // An image, a video or an audio file is shown, not refused as binary.
      if (mediaKindOf(path) != null) {
        return MediaPane(
          key: ValueKey(paneId),
          paneId: paneId,
          hostPath: path,
          showing: showing,
        );
      }
      return EditorTabView(key: ValueKey(paneId), hostPath: path);
    }
    if (notePaneNoteId(paneId) case final noteId?) {
      return NoteTabView(key: ValueKey(paneId), noteId: noteId);
    }
    // A session's conversation with no terminal behind it. The same gate as
    // Settings: off screen it would stream a transcript for nobody, and the
    // composer parks its draft on the way out.
    if (chatPaneSessionId(paneId) case final sessionId?) {
      return showing
          ? SessionTranscriptView(
              key: ValueKey(paneId),
              sessionId: sessionId,
              holdForPrompt: CompactWorkbenchScope.of(context),
            )
          : const SizedBox.shrink();
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
              terminalTheme: terminalThemeFor(theme, _schemePalette()),
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
      child: TerminalFileDrop(
        paneId: paneId,
        child: TerminalPresence(paneId: paneId, child: paneWithActions),
      ),
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

/// Somewhere for the keyboard to be while a document — Settings, Stores, a
/// device's preview — is the pane in front. A terminal takes focus when it is
/// shown; a page with no field of its own took none, so focus stayed parked
/// above the shell and its chords (Ctrl+W, Ctrl+Tab, Ctrl+P) never reached
/// [ShellShortcuts] (owner, 2026-10-01). Never taken from a field or a
/// device mirror already holding the keyboard, nor from inside the pane.
class _DocumentPaneFocus extends StatefulWidget {
  const _DocumentPaneFocus({required this.focused, required this.child});

  final bool focused;
  final Widget child;

  @override
  State<_DocumentPaneFocus> createState() => _DocumentPaneFocusState();
}

class _DocumentPaneFocusState extends State<_DocumentPaneFocus> {
  final _node = FocusNode(debugLabel: 'document pane', skipTraversal: true);

  @override
  void initState() {
    super.initState();
    if (widget.focused) _takeAfterFrame();
  }

  @override
  void didUpdateWidget(_DocumentPaneFocus oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focused && !oldWidget.focused) _takeAfterFrame();
  }

  void _takeAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.focused || _node.hasFocus) return;
      if (keyboardIsSpokenFor()) return;
      _node.requestFocus();
    });
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _node,
    // A click on the page's background gives it the keyboard back; a click
    // on a field inside takes it on from there.
    child: Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        if (!_node.hasFocus) _node.requestFocus();
      },
      child: widget.child,
    ),
  );
}
