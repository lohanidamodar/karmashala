/// Which terminal tabs keep a mounted widget subtree.
///
/// `IndexedStack` is preservation, not virtualization: hidden children stop
/// *painting* but stay mounted with their render objects, terminal controller,
/// focus node and layout. Measured at 5 291 render objects and a 65 ms tab
/// switch across 100 tabs, against 242 and 0.06 ms at one — linear in the
/// number of tabs, for panes nobody can see.
///
/// A pane's *process and buffer* live in `TerminalSessionsController` and are
/// untouched by this, so an unmounted tab keeps running, keeps its scrollback
/// and comes back with the same buffer; only its widgets are rebuilt.
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

  /// Re-derives the set from the layout. Called on every build rather than on
  /// every activation, so there is one path and no way for the set to drift
  /// from the tabs that exist: closed tabs drop out, the active tab is always
  /// held, and tabs never visited fill whatever room is left.
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
