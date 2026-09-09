part of 'workbench.dart';

// One tab's chip, and the strip's only watch on what happens inside a tab.

/// One tab's chip, holding the strip's only watch on what happens *inside* a
/// tab.
///
/// A tab draws a liveness dot, so the strip cannot simply stop knowing about
/// liveness — but it can stop being told as a whole. Each chip subscribes to
/// its own panes through [terminalPaneLivenessProvider], so a process exiting
/// redraws that tab and leaves the other ninety-nine alone.
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

  /// Where the strip laid this chip out, and how wide the row is. The chip
  /// itself reads no provider, so this is how it learns whether "close to the
  /// right" has anything to the right of it.
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
      // A document tab has nothing running in it, so it wears what it is
      // rather than a liveness dot reporting `exited` — see
      // [TerminalTabChip.icon].
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

    // Dropping a tab on a region of a split moves it there — VS Code's gesture,
    // and half the reason a split can be made empty at all. The payload says
    // which of the two draggable things this is (see [TerminalDrag]), because a
    // region header can send a *pane* the other way; the keyboard reaches the
    // same verbs from the region's own "Move a tab here…" and from the command
    // palette, because a drag alone is not an affordance everybody has.
    return Draggable<TerminalDrag>(
      data: TabDrag(tab.id),
      // The pointer, not the grab point: a drop target reads `details.offset`
      // to decide which half of itself the drag is over, and that offset is
      // the feedback's corner. Anchored to the child it was half a chip out,
      // which put every drop in the leading half whatever the pointer did.
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

  /// Names the workbench's shape and stores it.
  ///
  /// The name is asked for rather than generated: a preset nobody named is one
  /// nobody will recognise in the palette, and this is the one moment the user
  /// knows what the shape is *for*.
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

  /// Runs [scope], asking first when it would take a running session with it.
  ///
  /// The decision, stated once: a single close is a view action and detaching
  /// is right, but a bulk close is the user clearing the deck — and silently
  /// parking a dozen live agents in the background list is the outcome nobody
  /// wants. So the set is counted, and a set with anything live in it asks,
  /// with *end* as the default answer. A set with nothing live has no question
  /// to put, and simply closes.
  Future<void> _bulkClose(
    BuildContext context,
    WidgetRef ref,
    TabCloseScope scope,
  ) async {
    // Read now rather than trusting the index the chip was built with: a tab
    // can have gone between the menu opening and a row being picked. This
    // group's tabs, because this strip is the thing "to the right" is about.
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

  /// The strongest liveness among this tab's panes — `livenessForTab`'s rule,
  /// asked pane by pane so a split's second pane is watched too.
  ///
  /// Every pane is watched rather than stopping at the first live one: the
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

  /// What the agent in this tab is doing, or null when it holds none.
  ///
  /// Pane by pane for [_liveness]'s reason — the subscription set has to be the
  /// whole tab — and folded by [mostUrgentAgentActivity], which is where the
  /// choice between several agents in one tab is argued.
  ///
  /// Each of these watches is already narrowed twice over:
  /// [paneAgentActivityProvider] selects one key out of the shared
  /// paneId → sessionId map and then selects the status word out of the
  /// registry's report, so a 1.2 s cycle that reconfirms what a pane was
  /// already doing reaches no chip at all, and a cycle that changes one pane
  /// reaches one.
  AgentActivityStatus? _agentActivity(WidgetRef ref) => mostUrgentAgentActivity([
    for (final paneId in tab.layout.panes)
      ref.watch(paneAgentActivityProvider(paneId)),
  ]);
}
