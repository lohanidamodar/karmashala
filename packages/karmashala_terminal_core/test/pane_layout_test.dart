import 'dart:math' as math;

import 'package:karmashala_terminal_core/geometry.dart';
import 'package:flutter_test/flutter_test.dart';

/// Area shared by two rectangles; 0 when they only touch.
double _overlapArea(PaneRect a, PaneRect b) {
  final width = math.min(a.right, b.right) - math.max(a.left, b.left);
  final height = math.min(a.bottom, b.bottom) - math.max(a.top, b.top);
  if (width <= 0 || height <= 0) return 0;
  return width * height;
}

void main() {
  group('split', () {
    test('a single pane becomes a two-child split with equal weights', () {
      final layout = PaneLayout.single(
        'a',
      ).split('a', SplitAxis.horizontal, 'b', 's1');
      final root = layout.root as PaneSplit;
      expect(root.id, 's1');
      expect(root.axis, SplitAxis.horizontal);
      expect(layout.panes, ['a', 'b']);
      expect(root.weights, [0.5, 0.5]);
    });

    test('splitting on the parent axis adds a sibling instead of nesting', () {
      final layout = PaneLayout.single('a')
          .split('a', SplitAxis.horizontal, 'b', 's1')
          .split('b', SplitAxis.horizontal, 'c', 's2');
      final root = layout.root as PaneSplit;
      expect(root.children.every((c) => c is PaneGroup), isTrue);
      expect(layout.panes, ['a', 'b', 'c']);
      expect(root.weights[0], closeTo(0.5, 1e-9));
      expect(root.weights[1], closeTo(0.25, 1e-9));
      expect(root.weights[2], closeTo(0.25, 1e-9));
    });

    test('splitting on the opposite axis nests', () {
      final layout = PaneLayout.single('a')
          .split('a', SplitAxis.horizontal, 'b', 's1')
          .split('b', SplitAxis.vertical, 'c', 's2');
      final root = layout.root as PaneSplit;
      expect(root.children[1], isA<PaneSplit>());
      expect((root.children[1] as PaneSplit).axis, SplitAxis.vertical);
      expect(layout.panes, ['a', 'b', 'c']);
    });

    test('splitting an unknown pane leaves the layout alone', () {
      final layout = PaneLayout.single('a');
      expect(layout.split('zzz', SplitAxis.vertical, 'b', 's1').panes, ['a']);
    });
  });

  group('close', () {
    test('closing one of two collapses the split into the survivor', () {
      final layout = PaneLayout.single(
        'a',
      ).split('a', SplitAxis.horizontal, 'b', 's1');
      final closed = layout.close('a')!;
      expect(closed.root, isA<PaneGroup>());
      expect(closed.panes, ['b']);
    });

    test('closing the last pane returns null', () {
      expect(PaneLayout.single('a').close('a'), isNull);
    });

    test('closing cascades through every now-pointless ancestor', () {
      var layout = PaneLayout.single('a')
          .split('a', SplitAxis.horizontal, 'b', 's1')
          .split('b', SplitAxis.vertical, 'c', 's2');
      layout = layout.close('b')!;
      expect(layout.panes, ['a', 'c']);
      layout = layout.close('c')!;
      expect(layout.root, isA<PaneGroup>());
      expect(layout.panes, ['a']);
    });

    test('closing an unknown pane is a no-op', () {
      expect(PaneLayout.single('a').close('zzz')!.panes, ['a']);
    });

    test('the survivors of a close share the closed pane\'s weight', () {
      final layout = PaneLayout.single('a')
          .split('a', SplitAxis.horizontal, 'b', 's1')
          .split('b', SplitAxis.horizontal, 'c', 's2')
          .close('c')!;
      final root = layout.root as PaneSplit;
      expect(root.weights.reduce((x, y) => x + y), closeTo(1.0, 1e-9));
    });
  });

  group('deeply nested trees', () {
    PaneLayout deep() => PaneLayout.single('a')
        .split('a', SplitAxis.horizontal, 'b', 's1')
        .split('b', SplitAxis.vertical, 'c', 's2')
        .split('c', SplitAxis.horizontal, 'd', 's3')
        .split('d', SplitAxis.vertical, 'e', 's4');

    test('panes are listed depth-first, left to right', () {
      expect(deep().panes, ['a', 'b', 'c', 'd', 'e']);
    });

    test('rects tile the unit square with no gaps or overlaps', () {
      final rects = deep().rects();
      expect(rects.length, 5);

      var area = 0.0;
      for (final r in rects.values) {
        area += (r.right - r.left) * (r.bottom - r.top);
      }
      expect(area, closeTo(1.0, 1e-9));

      final values = rects.values.toList();
      for (var i = 0; i < values.length; i++) {
        for (var j = i + 1; j < values.length; j++) {
          expect(_overlapArea(values[i], values[j]), closeTo(0.0, 1e-9));
        }
      }
    });

    test('closing a leaf deep in the tree renormalizes the whole tree', () {
      final layout = deep().close('e')!;
      expect(layout.panes, ['a', 'b', 'c', 'd']);
      var area = 0.0;
      for (final r in layout.rects().values) {
        area += (r.right - r.left) * (r.bottom - r.top);
      }
      expect(area, closeTo(1.0, 1e-9));
    });
  });

  group('focus traversal', () {
    test('next and previous cycle and wrap', () {
      final layout = PaneLayout.single('a')
          .split('a', SplitAxis.horizontal, 'b', 's1')
          .split('b', SplitAxis.horizontal, 'c', 's2');
      expect(layout.nextPane('a'), 'b');
      expect(layout.nextPane('c'), 'a');
      expect(layout.previousPane('a'), 'c');
    });

    test('directional movement crosses three columns geometrically', () {
      final layout = PaneLayout.single('a')
          .split('a', SplitAxis.horizontal, 'b', 's1')
          .split('b', SplitAxis.horizontal, 'c', 's2');
      expect(layout.paneInDirection('a', PaneDirection.right), 'b');
      expect(layout.paneInDirection('b', PaneDirection.right), 'c');
      expect(layout.paneInDirection('c', PaneDirection.left), 'b');
    });

    test('movement past an edge returns null', () {
      final layout = PaneLayout.single(
        'a',
      ).split('a', SplitAxis.horizontal, 'b', 's1');
      expect(layout.paneInDirection('a', PaneDirection.left), isNull);
      expect(layout.paneInDirection('a', PaneDirection.up), isNull);
      expect(layout.paneInDirection('b', PaneDirection.right), isNull);
    });

    test('down crosses a nested vertical split, not the tree sibling', () {
      final layout = PaneLayout.single('a')
          .split('a', SplitAxis.horizontal, 'b', 's1')
          .split('b', SplitAxis.vertical, 'c', 's2');
      expect(layout.paneInDirection('b', PaneDirection.down), 'c');
      expect(layout.paneInDirection('a', PaneDirection.down), isNull);
      expect(layout.paneInDirection('c', PaneDirection.left), 'a');
    });

    test('a single pane has nowhere to go', () {
      final layout = PaneLayout.single('a');
      expect(layout.nextPane('a'), 'a');
      expect(layout.paneInDirection('a', PaneDirection.right), isNull);
    });
  });

  group('resize', () {
    test('moves weight between neighbours', () {
      final layout = PaneLayout.single(
        'a',
      ).split('a', SplitAxis.horizontal, 'b', 's1');
      final root = layout.resize('s1', 0, 0.2).root as PaneSplit;
      expect(root.weights[0], closeTo(0.7, 1e-9));
      expect(root.weights[1], closeTo(0.3, 1e-9));
    });

    test('clamps so no child drops below the minimum weight', () {
      final layout = PaneLayout.single(
        'a',
      ).split('a', SplitAxis.horizontal, 'b', 's1');
      final root = layout.resize('s1', 0, 5.0).root as PaneSplit;
      expect(root.weights[1], closeTo(kMinPaneWeight, 1e-9));
      expect(root.weights[0], closeTo(1 - kMinPaneWeight, 1e-9));
    });

    test('an unknown split id is a no-op', () {
      final layout = PaneLayout.single(
        'a',
      ).split('a', SplitAxis.horizontal, 'b', 's1');
      final root = layout.resize('nope', 0, 0.2).root as PaneSplit;
      expect(root.weights, [0.5, 0.5]);
    });
  });

  group('json', () {
    test('round-trips a nested tree', () {
      final layout = PaneLayout.single('a')
          .split('a', SplitAxis.horizontal, 'b', 's1')
          .split('b', SplitAxis.vertical, 'c', 's2');
      final restored = PaneLayout.fromJson(layout.toJson())!;
      expect(restored.panes, layout.panes);
      expect(restored.rects().keys, layout.rects().keys);
      expect((restored.root as PaneSplit).axis, SplitAxis.horizontal);
      expect(
        (restored.root as PaneSplit).children[1],
        isA<PaneSplit>().having((s) => s.axis, 'axis', SplitAxis.vertical),
      );
    });

    test('returns null for malformed json instead of throwing', () {
      expect(PaneLayout.fromJson(null), isNull);
      expect(PaneLayout.fromJson('nonsense'), isNull);
      expect(PaneLayout.fromJson(<String, Object?>{'t': 'split'}), isNull);
      expect(PaneLayout.fromJson(<String, Object?>{'t': 'leaf'}), isNull);
      expect(
        PaneLayout.fromJson(<String, Object?>{
          't': 'split',
          'id': 's1',
          'axis': 'h',
          'w': [1.0],
          'c': [
            {'t': 'leaf', 'id': 'a'},
            {'t': 'leaf', 'id': 'b'},
          ],
        }),
        isNull,
        reason: 'weights and children must be the same length',
      );
    });
  });

  group('withoutMissing', () {
    test('drops panes that no longer exist and renormalizes', () {
      final layout = PaneLayout.single('a')
          .split('a', SplitAxis.horizontal, 'b', 's1')
          .split('b', SplitAxis.vertical, 'c', 's2');
      final pruned = layout.withoutMissing({'a', 'c'})!;
      expect(pruned.panes, ['a', 'c']);
      expect(pruned.root, isA<PaneSplit>());
      expect(
        (pruned.root as PaneSplit).children.every((c) => c is PaneGroup),
        isTrue,
      );
    });

    test('returns null when nothing survives', () {
      expect(PaneLayout.single('a').withoutMissing({'x'}), isNull);
    });

    test('keeps an intact layout unchanged', () {
      final layout = PaneLayout.single(
        'a',
      ).split('a', SplitAxis.horizontal, 'b', 's1');
      expect(layout.withoutMissing({'a', 'b'})!.panes, ['a', 'b']);
    });
  });

  /// What moving a tab into an empty region of a split is made of.
  ///
  /// An empty region is a region like any other, so filling it swaps the whole
  /// region — for one pane, or for the whole pane tree of the tab being moved in.
  group('replaceRegion', () {
    test('swaps one region for another, keeping its place and its share', () {
      final layout = PaneLayout.single(
        'a',
      ).split('a', SplitAxis.horizontal, 'slot', 's1').resize('s1', 0, 0.2);
      final filled = layout.replaceRegion('slot', PaneGroup.of('b'));

      expect(filled.panes, ['a', 'b']);
      expect((filled.root as PaneSplit).weights[0], closeTo(0.7, 1e-9));
    });

    test('a whole sub-tree can take a region\'s place', () {
      final target = PaneLayout.single(
        'a',
      ).split('a', SplitAxis.horizontal, 'slot', 's1');
      final incoming = PaneLayout.single(
        'b',
      ).split('b', SplitAxis.vertical, 'c', 's2');

      final merged = target.replaceRegion('slot', incoming.root);

      expect(merged.panes, ['a', 'b', 'c']);
      final root = merged.root as PaneSplit;
      expect(root.axis, SplitAxis.horizontal);
      expect(root.children[1], isA<PaneSplit>());
    });

    test('a sub-tree on the parent axis is flattened, not nested', () {
      final target = PaneLayout.single(
        'a',
      ).split('a', SplitAxis.horizontal, 'slot', 's1');
      final incoming = PaneLayout.single(
        'b',
      ).split('b', SplitAxis.horizontal, 'c', 's2');

      final merged = target.replaceRegion('slot', incoming.root);

      expect(merged.panes, ['a', 'b', 'c']);
      expect(
        (merged.root as PaneSplit).children.every((c) => c is PaneGroup),
        isTrue,
        reason: 'three columns, not a column holding two',
      );
    });

    test('replacing the only region makes the incoming node the root', () {
      final filled = PaneLayout.single(
        'slot',
      ).replaceRegion('slot', PaneGroup.of('a'));
      expect(filled.panes, ['a']);
      expect(filled.root, isA<PaneGroup>());
    });

    test('an unknown pane leaves the layout alone', () {
      final layout = PaneLayout.single('a');
      expect(layout.replaceRegion('zzz', PaneGroup.of('b')).panes, ['a']);
    });
  });
}
