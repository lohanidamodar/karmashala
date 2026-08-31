/// Which terminal tabs keep a mounted widget subtree.
///
/// `IndexedStack` is preservation, not virtualization: it stops hidden children
/// *painting*, but every child stays mounted with its render objects, terminal
/// controller, focus node, scroll client and layout. Measured on the reference
/// machine with `tool/benchmark/terminal_scale_bench.dart`: 5 291 render
/// objects and a 65 ms tab switch at 100 tabs, against 242 and 0.06 ms at one —
/// both linear in the number of tabs, for panes nobody can see.
///
/// The fix is a bounded hot set. A pane's *process and buffer* live in
/// `TerminalSessionsController` and are untouched by this, so an unmounted tab
/// keeps running, keeps its scrollback and comes back with the same buffer —
/// only its widgets are rebuilt.
library;

/// How many tabs keep a mounted view.
///
/// Eight rather than four: a mounted tab is what makes a switch instant, and
/// the audit's own suggestion is 4–12. Eight covers the tabs anyone cycles
/// between in a session while capping the mounted cost at roughly a twelfth of
/// what a hundred open tabs used to pay.
const int kMountedTabBudget = 8;

/// The bounded set of tabs whose views stay mounted, in most-recently-active
/// order.
///
/// Deliberately Flutter-free so the eviction policy is unit-testable without a
/// widget tree — the widget only asks it what to build.
class MountedTabs {
  MountedTabs({this.budget = kMountedTabBudget}) : assert(budget > 0);

  final int budget;

  final List<String> _mru = [];

  /// The tabs currently held, most recently active first.
  List<String> get ids => List.unmodifiable(_mru);

  bool contains(String tabId) => _mru.contains(tabId);

  /// Re-derives the set from the workspace.
  ///
  /// Called on every build rather than on every activation, so there is one
  /// path and no way for the set to drift from the tabs that actually exist:
  /// closed tabs drop out, the active tab is always held, and tabs never
  /// visited fill whatever room is left — which is what a restored workspace
  /// looks like before the user has touched any of it.
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
