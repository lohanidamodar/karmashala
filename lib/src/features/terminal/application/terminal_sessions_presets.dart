part of 'terminal_sessions_controller.dart';

// `Notifier.ref` is `@protected`, which covers a subclass and not an extension
// splitting that subclass's own body inside its own library.
// ignore_for_file: invalid_use_of_protected_member

/// **Presets**: capturing the workbench's shape under a name, and opening one
/// back up. The distinction it turns on is [openPreset]'s: the tab that ends up
/// in front starts, and the rest declare.
extension TerminalPresetVerbs on TerminalSessionsController {
  /// Captures the workbench's shape under [name] — and **nothing that is
  /// running**. The pane's *current* directory (OSC 7), not its launch one; an
  /// empty region declares nothing and is left out.
  TerminalPreset capturePreset({required String id, required String name}) {
    final tabs = <PresetTab>[];
    var active = 0;
    for (final tab in _tabs) {
      final panes = <PresetPane>[
        for (final paneId in tab.layout.panes)
          if (_instances[paneId] case final instance?)
            PresetPane(
              id: paneId,
              profileId: instance.profileId,
              workingDirectory:
                  instance.directory.value ?? instance.workingDirectory,
            ),
      ];
      if (panes.isEmpty) continue;
      final layout = tab.layout.withoutMissing({
        for (final pane in panes) pane.id,
      });
      if (layout == null) continue;
      if (tab.id == _activeTabId) active = tabs.length;
      tabs.add(
        PresetTab(
          layout: layout,
          focusedPaneId: layout.contains(tab.focusedPaneId)
              ? tab.focusedPaneId
              : layout.visiblePanes.first,
          panes: panes,
        ),
      );
    }
    return TerminalPreset(id: id, name: name, tabs: tabs, activeTab: active);
  }

  /// Opens [preset] as fresh tabs, and reports what it could not open.
  ///
  /// **The tab that ends up in front starts; the rest declare** — a preset that
  /// launched nine processes would be worse than no preset. A profile this
  /// machine no longer has is skipped and named, unlike [_adoptRestored]: for
  /// something chosen by name, that is more use than a pane that will not start.
  TerminalPresetOpening openPreset(TerminalPreset preset) {
    final available = {
      for (final profile in ref.read(terminalProfilesProvider)) profile.id,
    };
    final skipped = <String>[];
    var openedTabs = 0;
    var openedPanes = 0;
    String? activate;

    for (final (index, presetTab) in preset.tabs.indexed) {
      final eager = index == preset.activeTab;
      final ids = <String, String>{};
      for (final pane in presetTab.panes) {
        final profile = terminalProfileFromId(pane.profileId);
        if (profile == null || !available.contains(profile.id)) {
          if (!skipped.contains(pane.profileId)) skipped.add(pane.profileId);
          continue;
        }
        ids[pane.id] = eager
            ? _createPane(profile, workingDirectory: pane.workingDirectory)
            : _declarePane(profile, pane.workingDirectory);
      }
      if (ids.isEmpty) continue;

      final layout = remapPaneIds(
        presetTab.layout,
        (id) => ids[id] ?? id,
        _newId,
      ).withoutMissing(ids.values.toSet());
      if (layout == null) continue;

      final focused = ids[presetTab.focusedPaneId];
      final stayed = focused != null && layout.contains(focused);
      final tabId = _newId();
      _tabs.add(
        TerminalTab(
          id: tabId,
          layout: stayed ? layout.activate(focused) : layout,
          focusedPaneId: stayed ? focused : layout.visiblePanes.first,
        ),
      );
      _tabsMutated();
      openedTabs++;
      openedPanes += ids.length;
      // The preset's own front tab wins; the first opened is the fallback for
      // a preset whose front tab was entirely skipped.
      if (eager || activate == null) activate = tabId;
    }

    if (activate != null) {
      _activeTabId = activate;
      _publish();
      persistStructure();
      _focusActivePane();
    }
    return TerminalPresetOpening(
      openedTabs: openedTabs,
      openedPanes: openedPanes,
      skippedProfileIds: skipped,
    );
  }
}
