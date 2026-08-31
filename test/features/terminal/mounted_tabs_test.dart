import 'package:chitragupta/src/features/terminal/domain/mounted_tabs.dart';
import 'package:flutter_test/flutter_test.dart';

/// The eviction policy behind the bounded mounted set, on its own — no widget
/// tree, because none of these answers depend on one.
void main() {
  test('every tab is mounted while the workspace fits in the budget', () {
    final mounted = MountedTabs(budget: 4);

    mounted.sync(openTabIds: ['a', 'b', 'c'], activeTabId: 'c');

    expect(mounted.ids, containsAll(['a', 'b', 'c']));
  });

  test('the active tab is always mounted, however long it has been away', () {
    final mounted = MountedTabs(budget: 2);
    final tabs = ['a', 'b', 'c', 'd'];

    mounted.sync(openTabIds: tabs, activeTabId: 'a');
    mounted.sync(openTabIds: tabs, activeTabId: 'b');
    mounted.sync(openTabIds: tabs, activeTabId: 'd');

    expect(mounted.ids.first, 'd');
    expect(mounted.contains('d'), isTrue);
  });

  test('the least recently active tab falls out at the budget', () {
    final mounted = MountedTabs(budget: 2);
    final tabs = ['a', 'b', 'c'];

    mounted.sync(openTabIds: tabs, activeTabId: 'a');
    mounted.sync(openTabIds: tabs, activeTabId: 'b');
    mounted.sync(openTabIds: tabs, activeTabId: 'c');

    expect(mounted.ids, ['c', 'b']);
    expect(mounted.contains('a'), isFalse);
  });

  test('a hundred tabs mount no more than the budget', () {
    final mounted = MountedTabs(budget: 8);
    final tabs = [for (var i = 0; i < 100; i++) 'tab$i'];

    mounted.sync(openTabIds: tabs, activeTabId: 'tab99');

    expect(mounted.ids.length, 8);
    expect(mounted.contains('tab99'), isTrue);
  });

  test('closed tabs are dropped rather than holding a slot', () {
    final mounted = MountedTabs(budget: 3);

    mounted.sync(openTabIds: ['a', 'b', 'c'], activeTabId: 'a');
    mounted.sync(openTabIds: ['a'], activeTabId: 'a');

    expect(mounted.ids, ['a']);
  });

  test('a restored workspace mounts tabs nobody has activated yet', () {
    final mounted = MountedTabs(budget: 3);

    // What a restore looks like: tabs exist, none has been switched to.
    mounted.sync(openTabIds: ['a', 'b', 'c', 'd'], activeTabId: null);

    expect(mounted.ids.length, 3);
  });

  test('an active tab that is no longer open does not resurrect itself', () {
    final mounted = MountedTabs(budget: 3);

    mounted.sync(openTabIds: ['a', 'b'], activeTabId: 'gone');

    expect(mounted.contains('gone'), isFalse);
    expect(mounted.ids, containsAll(['a', 'b']));
  });
}
