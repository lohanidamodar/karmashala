/// Which terminal tabs keep a mounted widget subtree. `IndexedStack` is
/// preservation, not virtualization: 100 tabs cost 5 291 render objects.
library;

/// How many tabs keep a mounted view. Eight rather than four: a mounted tab is
/// what makes a switch instant, and eight covers the tabs anyone cycles between
/// in a session while capping the mounted cost at a twelfth of a hundred.
const int kMountedTabBudget = 8;

/// The bounded set of tabs whose views stay mounted, in most-recently-active
/// order. Deliberately Flutter-free, so the eviction policy is unit-testable
/// without a widget tree — the widget only asks it what to build.
class MountedTabs {
  MountedTabs({this.budget = kMountedTabBudget}) : assert(budget > 0);

  final int budget;

  final List<String> _mru = [];

  /// The tabs currently held, most recently active first.
  List<String> get ids => List.unmodifiable(_mru);

  bool contains(String tabId) => _mru.contains(tabId);

  /// Re-derives the set from the layout on every build, so it cannot drift from
  /// the tabs that exist: closed tabs drop out and the active tab is held.
  void sync({required Iterable<String> openTabIds, String? activeTabId}) {
    final open = openTabIds.toSet();
    _mru.removeWhere((id) => !open.contains(id));
    if (activeTabId != null && open.contains(activeTabId)) {
      _mru
        ..remove(activeTabId)
        ..insert(0, activeTabId);
    }
    if (_mru.length < budget) {
      for (final id in openTabIds) {
        if (_mru.length >= budget) break;
        if (!_mru.contains(id)) _mru.add(id);
      }
    }
    if (_mru.length > budget) _mru.removeRange(budget, _mru.length);
  }
}
