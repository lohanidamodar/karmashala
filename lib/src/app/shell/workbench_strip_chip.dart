part of 'workbench.dart';

/// One tab's chip, holding the strip's only watch on what happens *inside* a
/// tab.
///
/// Each chip subscribes to its own panes through [terminalPaneLivenessProvider],
/// so a process exiting redraws that tab and leaves the other ninety-nine alone.
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
    final sessions = ref.read(terminalSessionsControllerProvider.notifier);
    final title = ref.watch(terminalTabTitleProvider(tab.id));
    final chip = TerminalTabChip(
      title: title,
      liveness: _liveness(ref),
      agentStatus: _agentActivity(ref),
      // A document tab has nothing running in it, so it wears what it is rather
      // than a liveness dot reporting `exited`.
      icon:
          tab.layout.panes.length == 1 &&
              isSettingsPane(tab.layout.panes.single)
          ? AppIcons.gearSix
          : null,
      selected: selected,
      accented: accented,
      index: index,
      tabCount: tabCount,
      onTap: () => activateTerminalTab(ref, tab.id),
      onClose: () => sessions.closeTab(tab.id),
      onEnd: () => sessions.closeTab(tab.id, detach: false),
      onBulkClose: (scope) => _bulkClose(context, ref, scope),
      onSavePreset: () => _savePreset(context, ref),
    );

    // Dropping a tab on a region of a split moves it there. The payload says
    // which of the two draggable things this is (see [TerminalDrag]).
    return Draggable<TerminalDrag>(
      data: TabDrag(tab.id),
      // The pointer, not the grab point: a drop target reads `details.offset`,
      // which is the feedback's corner — anchored to the child it was half a
      // chip out, putting every drop in the leading half.
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

  Future<String?> _promptPresetName(BuildContext context) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const DesktopDialogTitle(
          icon: AppIcons.terminalWindow,
          title: 'Save this layout as a preset',
          subtitle: 'The shape only — which panes, split how, running what and '
              'where. Opening it later starts fresh terminals.',
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (value) =>
              Navigator.of(context).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    ).then((value) => (value == null || value.isEmpty) ? null : value);
  }

  /// Runs [scope], asking first when it would take a running session with it: a
  /// single close is a view action, but a bulk close that silently parks a dozen
  /// live agents in the background list is the outcome nobody wants.
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
        : ref.read(terminalSessionsControllerProvider.notifier).tabsInGroup(
            group,
          );
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

    if (live == 0) {
      sessions.closeTabs(ids, activate: tab.id);
      return;
    }
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
  }

  /// The strongest liveness among this tab's panes, asked pane by pane: the
  /// subscription set has to be the whole tab, or a pane this chip never asked
  /// about could die unnoticed.
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
  /// pane for [_liveness]'s reason, folded by [mostUrgentAgentActivity];
  /// [paneAgentActivityProvider] is narrowed twice, so a cycle that reconfirms
  /// what a pane was already doing reaches no chip at all.
  AgentActivityStatus? _agentActivity(WidgetRef ref) => mostUrgentAgentActivity([
    for (final paneId in tab.layout.panes)
      ref.watch(paneAgentActivityProvider(paneId)),
  ]);
}
