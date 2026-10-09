part of 'terminal_sessions_controller.dart';

/// The desktop's **pinned** tab: the Agent dashboard, always open, first in
/// its strip, and past every close — so a session revealed from a
/// notification always has a dashboard to land on (owner, 2026-10-09).
extension TerminalPinnedDashboard on TerminalSessionsController {
  /// Pins the Agent dashboard: opens it when it is not open — in front only
  /// when nothing else is — and moves it first in its strip. Asking again
  /// puts it back first.
  void pinDashboard() {
    _dashboardPinned = true;
    final open = _tabContaining(kOverviewPaneId);
    final tabId =
        open?.id ??
        openDocumentTab(
          kOverviewPaneId,
          behind: _tabs.isEmpty ? null : const OpenBehind(),
        );
    // Not new: it is always there, so there is nothing to have missed.
    if (_unseen.remove(tabId)) _unseenView = null;
    if (!reorderTab(tabId, 0)) _publish();
  }

  /// Whether [tabId] is the pinned tab.
  bool isPinnedTab(String tabId) => tabId == _pinnedTabId;

  /// [tabIds] without the pinned tab: what a close may take.
  List<String> _closable(Iterable<String> tabIds) => [
    for (final id in tabIds)
      if (!isPinnedTab(id)) id,
  ];

  String? get _pinnedTabId =>
      _dashboardPinned ? _tabContaining(kOverviewPaneId)?.id : null;
}
