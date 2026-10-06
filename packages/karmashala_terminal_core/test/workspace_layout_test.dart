import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_terminal_core/geometry.dart';

void main() {
  _insertBehindTests();

  group('room to split a group', () {
    test('is asked of the workspace, not of the split the group sits in', () {
      // Half of a quarter-wide group is an eighth of the window, whatever
      // share of its own row that quarter is.
      var tree = PaneLayout.single('a');
      tree = tree.split('a', SplitAxis.horizontal, 'b', 's1');
      tree = tree.split('b', SplitAxis.vertical, 'c', 's2');
      tree = tree.split('c', SplitAxis.horizontal, 'd', 's3');

      expect(tree.rects()['d']!.width, 0.25);
      expect(groupHasRoomToSplit(tree, 'd', SplitAxis.horizontal), isTrue);
      expect(groupHasRoomToSplit(tree, 'd', SplitAxis.vertical), isTrue);
    });

    test('runs out when a half would be under the floor a divider keeps', () {
      var tree = PaneLayout.single('a');
      var last = 'a';
      for (var i = 0; i < 4; i++) {
        final next = emptyGroupSlotId('$i');
        tree = tree.split(last, SplitAxis.horizontal, next, 's$i');
        last = next;
      }

      expect(tree.rects()[last]!.width, 0.0625);
      expect(0.0625 / 2, lessThan(kMinPaneWeight));
      expect(groupHasRoomToSplit(tree, last, SplitAxis.horizontal), isFalse);
      // The other axis is untouched: the sliver is still the window's height.
      expect(groupHasRoomToSplit(tree, last, SplitAxis.vertical), isTrue);
      // And so is the half of the window nobody cut.
      expect(groupHasRoomToSplit(tree, 'a', SplitAxis.horizontal), isTrue);
    });

    test('an id the tree does not hold has no room at all', () {
      final tree = PaneLayout.single('a');

      expect(groupHasRoomToSplit(tree, 'nope', SplitAxis.horizontal), isFalse);
    });
  });
}

void _insertBehindTests() {
  group('a pane put behind', () {
    PaneLayout strip() => PaneLayout(
      PaneGroup('g', panes: const ['a', 'b', 'c'], activePaneId: 'c'),
    );

    test('lands right after the pane it is placed by, and the front stays', () {
      final tree = strip().insertBehind('a', 'n');

      expect(tree.groupById('g')!.panes, ['a', 'n', 'b', 'c']);
      expect(tree.groupById('g')!.activePaneId, 'c');
    });

    test('lands at the end of the region when asked to', () {
      final tree = strip().insertBehind('a', 'n', atEnd: true);

      expect(tree.groupById('g')!.panes, ['a', 'b', 'c', 'n']);
      expect(tree.groupById('g')!.activePaneId, 'c');
    });

    test('goes into the anchor\'s own region, leaving the others alone', () {
      var tree = PaneLayout.single('a');
      tree = tree.split('a', SplitAxis.horizontal, 'x', 's1');
      final before = tree.groupOf('x')!;

      tree = tree.insertBehind('a', 'n');

      expect(tree.groupOf('n')!.id, tree.groupOf('a')!.id);
      expect(tree.groupOf('a')!.activePaneId, 'a');
      expect(tree.groupOf('x')!.panes, before.panes);
    });

    test('an anchor the tree does not hold, or a pane it already has, '
        'changes nothing', () {
      final tree = strip();

      expect(identical(tree.insertBehind('nope', 'n'), tree), isTrue);
      expect(identical(tree.insertBehind('a', 'b'), tree), isTrue);
    });
  });
}
