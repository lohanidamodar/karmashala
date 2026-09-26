part of 'workbench.dart';

/// One tab's chip, holding the strip's only watch on what happens *inside* a
/// tab: [terminalPaneLivenessProvider] per chip, so one exit redraws one tab.
class _TabChip extends ConsumerWidget {
  const _TabChip({
    required this.tab,
    required this.groupId,
    required this.selected,
    required this.accented,
    required this.index,
    required this.tabCount,
  });

  final TerminalTab tab;

  /// The strip this chip hangs in. A bulk close is scoped to it: *close to the
  /// right* means the right of **this** strip, not of the window.
  final String? groupId;

  final bool selected;

  /// Whether this strip's group has the keyboard.
  final bool accented;

  /// Where the strip laid this chip out, and how wide the row is: how the chip
  /// learns whether "close to the right" has anything to the right of it.
  final int index;
  final int tabCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final title = ref.watch(terminalTabTitleProvider(tab.id));
    final chip = TerminalTabChip(
      title: title,
      liveness: _liveness(ref),
      agentStatus: _agentActivity(ref),
      // A document tab has nothing running in it, so it wears what it is rather
      // than a liveness dot reporting `exited`.
      icon: _documentIconFor(tab),
      unsaved: _hasUnsaved(ref),
      selected: selected,
      accented: accented,
      index: index,
      tabCount: tabCount,
      onTap: () => activateTerminalTab(ref, tab.id),
      onClose: () => _close(context, ref),
      onEnd: () => _close(context, ref, detach: false),
      onBulkClose: (scope) => _bulkClose(context, ref, scope),
      onSavePreset: () => _savePreset(context, ref),
    );

    // Dropping a tab on a region of a split moves it there. The payload says
    // which of the two draggable things this is (see [TerminalDrag]).
    return Draggable<TerminalDrag>(
      data: TabDrag(tab.id),
      // The pointer, not the grab point: a drop target reads `details.offset`,
      // the feedback's corner, which put every drop in the leading half.
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _TabDragFeedback(title: title),
      childWhenDragging: Opacity(opacity: 0.4, child: chip),
      child: _TabDropTarget(
        index: index,
        tab: tab,
        groupId: groupId,
        chip: chip,
      ),
    );
  }

  /// Names the workbench's shape and stores it. The name is asked for rather
  /// than generated: this is the moment the user knows what the shape is for.
  Future<void> _savePreset(BuildContext context, WidgetRef ref) async {
    final name = await _promptPresetName(context);
    if (name == null || !context.mounted) return;
    final preset = ref.read(terminalPresetsProvider).save(name);
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          preset == null
              // Not "saved": a workbench of empty regions declares nothing, and
              // a preset that opens to nothing is worse than no preset.
              ? 'Nothing to save — no pane here is running anything.'
              : 'Saved "${preset.name}" — ${preset.paneCount} pane'
                    '${preset.paneCount == 1 ? '' : 's'}. '
                    'Open it from quick open with ~.',
        ),
      ),
    );
  }

  Future<String?> _promptPresetName(BuildContext context) =>
      SavePresetNameDialog.show(context);

  /// Closes this tab, asking first when it holds edits that are not on disk.
  Future<void> _close(
    BuildContext context,
    WidgetRef ref, {
    bool detach = true,
  }) async {
    final sessions = ref.read(terminalSessionsControllerProvider.notifier);
    await closeEditors(context, ref, [
      tab.id,
    ], () => sessions.closeTab(tab.id, detach: detach));
  }

  /// Whether any editor pane in this tab has unsaved edits. Narrowed twice, so
  /// a tab holding no file never subscribes to the set at all.
  bool _hasUnsaved(WidgetRef ref) {
    if (_tabHasConflictedNote(ref, tab)) return true;
    final paths = [
      for (final paneId in tab.layout.panes) ?editorPanePath(paneId),
    ];
    if (paths.isEmpty) return false;
    return ref.watch(
      dirtyDocumentPathsProvider.select((dirty) => paths.any(dirty.contains)),
    );
  }

  /// Runs [scope], asking first when it would take a running session with it: a
  /// bulk close that silently parks a dozen live agents is nobody's intent.
  Future<void> _bulkClose(
    BuildContext context,
    WidgetRef ref,
    TabCloseScope scope,
  ) async {
    // Read now rather than trusting the index the chip was built with: a tab
    // can have gone between the menu opening and a row being picked.
    final group = groupId;
    final tabs = group == null
        ? ref.read(terminalTabsProvider)
        : ref
              .read(terminalSessionsControllerProvider.notifier)
              .tabsInGroup(group);
    final at = tabs.indexWhere((candidate) => candidate.id == tab.id);
    if (at < 0) return;
    final ids = scope.apply([for (final tab in tabs) tab.id], at);
    if (ids.isEmpty) return;

    final sessions = ref.read(terminalSessionsControllerProvider.notifier);
    final state = ref.read(terminalSessionsControllerProvider);
    final closing = {for (final tab in tabs) tab.id: tab};
    final live = ids
        .where(
          (id) => closing[id]!.layout.panes.any(
            (paneId) => state.livenessOf(paneId).isLive,
          ),
        )
        .length;

    if (!context.mounted) return;
    // Asked before the second question and released only after the close, or
    // cancelling the *live sessions* dialog would have thrown the edits away
    // and left every editor pane with no document to draw.
    if (!await confirmEditorsClosable(context, ref, ids)) return;
    final editors = ref.read(editorTabActionsProvider);
    final paths = editors.pathsIn(ids);
    if (live == 0) {
      sessions.closeTabs(ids, activate: tab.id);
      editors.release(paths);
      return;
    }
    if (!context.mounted) return;
    final choice = await confirmBulkTabClose(
      context,
      tabs: ids.length,
      live: live,
    );
    if (choice == null || !context.mounted) return;
    sessions.closeTabs(
      ids,
      detach: choice == BulkCloseChoice.keepRunning,
      activate: tab.id,
    );
    editors.release(paths);
  }

  /// The strongest liveness among this tab's panes, asked pane by pane: the
  /// subscription has to be the whole tab, or a pane could die unnoticed.
  PaneLiveness _liveness(WidgetRef ref) {
    var strongest = PaneLiveness.exited;
    for (final paneId in tab.layout.panes) {
      final liveness = ref.watch(terminalPaneLivenessProvider(paneId));
      if (liveness == PaneLiveness.live) {
        strongest = PaneLiveness.live;
      } else if (liveness == PaneLiveness.restored &&
          strongest != PaneLiveness.live) {
        strongest = PaneLiveness.restored;
      }
    }
    return strongest;
  }

  /// What the agent in this tab is doing, or null when it holds none. Pane by
  /// pane for [_liveness]'s reason; [paneAgentActivityProvider] is narrowed twice.
  AgentActivityStatus? _agentActivity(WidgetRef ref) =>
      mostUrgentAgentActivity([
        for (final paneId in tab.layout.panes)
          ref.watch(paneAgentActivityProvider(paneId)),
      ]);
}

/// Asks for a preset's name. Owns its field's controller, so the controller
/// goes when the dialog does.
class SavePresetNameDialog extends StatefulWidget {
  const SavePresetNameDialog({super.key});

  /// The trimmed name, or null when cancelled or left blank.
  static Future<String?> show(BuildContext context) => showDialog<String>(
    context: context,
    builder: (_) => const SavePresetNameDialog(),
  ).then((value) => (value == null || value.isEmpty) ? null : value);

  @override
  State<SavePresetNameDialog> createState() => _SavePresetNameDialogState();
}

class _SavePresetNameDialogState extends State<SavePresetNameDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const DesktopDialogTitle(
      icon: AppIcons.terminalWindow,
      title: 'Save this layout as a preset',
      subtitle:
          'The shape only — which panes, split how, running what and '
          'where. Opening it later starts fresh terminals.',
    ),
    content: TextField(
      controller: _controller,
      autofocus: true,
      decoration: const InputDecoration(labelText: 'Name'),
      onSubmitted: (_) => _save(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _save, child: const Text('Save')),
    ],
  );
}
