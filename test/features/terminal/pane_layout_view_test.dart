import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala/src/features/terminal/presentation/pane_layout_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// A leaf that records every time it is actually painted.
///
/// This is the whole point of the file: Loop 26's win depends on hidden panes
/// costing no paint, and only a real paint count can prove that.
class PaintCounter extends SingleChildRenderObjectWidget {
  const PaintCounter({super.key, required this.counts, required this.name})
    : super(child: const SizedBox.expand());

  final Map<String, int> counts;
  final String name;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderPaintCounter(counts, name);

  @override
  void updateRenderObject(BuildContext context, RenderPaintCounter renderer) {
    renderer
      ..counts = counts
      ..name = name;
  }
}

class RenderPaintCounter extends RenderProxyBox {
  RenderPaintCounter(this.counts, this.name);

  Map<String, int> counts;
  String name;

  @override
  void paint(PaintingContext context, Offset offset) {
    counts[name] = (counts[name] ?? 0) + 1;
    super.paint(context, offset);
  }
}

/// [MaterialApp.home] hands its child tight constraints, so a bare `SizedBox`
/// there is ignored — the alignment is what lets the size take effect.
Widget sized(Widget child) => MaterialApp(
  home: Align(
    alignment: Alignment.topLeft,
    child: SizedBox(width: 800, height: 400, child: child),
  ),
);

void main() {
  testWidgets('every pane of a visible tab paints', (tester) async {
    final counts = <String, int>{};
    final layout = PaneLayout.single('a')
        .split('a', SplitAxis.horizontal, 'b', 's1')
        .split('b', SplitAxis.vertical, 'c', 's2');

    await tester.pumpWidget(
      MaterialApp(
        home: PaneLayoutView(
          layout: layout,
          regionBuilder: (group) =>
              PaintCounter(counts: counts, name: group.activePaneId),
        ),
      ),
    );

    expect(counts['a'], greaterThan(0));
    expect(counts['b'], greaterThan(0));
    expect(counts['c'], greaterThan(0));
  });

  testWidgets('panes in an inactive tab never paint', (tester) async {
    final counts = <String, int>{};

    await tester.pumpWidget(
      MaterialApp(
        home: IndexedStack(
          index: 0,
          children: [
            PaneLayoutView(
              layout: PaneLayout.single(
                'visible',
              ).split('visible', SplitAxis.horizontal, 'visible2', 's1'),
              regionBuilder: (group) =>
              PaintCounter(counts: counts, name: group.activePaneId),
            ),
            PaneLayoutView(
              layout: PaneLayout.single(
                'hidden',
              ).split('hidden', SplitAxis.vertical, 'hidden2', 's2'),
              regionBuilder: (group) =>
              PaintCounter(counts: counts, name: group.activePaneId),
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    expect(counts['visible'], greaterThan(0));
    expect(
      counts['visible2'],
      greaterThan(0),
      reason: 'the test must not pass by painting nothing at all',
    );
    expect(
      counts['hidden'],
      isNull,
      reason: 'a hidden tab must cost no paint — this is the Loop 26 property',
    );
    expect(counts['hidden2'], isNull);
  });

  testWidgets('a single pane fills the whole area', (tester) async {
    await tester.pumpWidget(
      sized(
        PaneLayoutView(
          layout: PaneLayout.single('a'),
          regionBuilder: (group) =>
              SizedBox.expand(key: ValueKey(group.activePaneId)),
        ),
      ),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('a'))),
      const Size(800, 400),
    );
  });

  testWidgets('weights decide the pane sizes', (tester) async {
    final layout = PaneLayout.single(
      'a',
    ).split('a', SplitAxis.horizontal, 'b', 's1').resize('s1', 0, 0.25);

    await tester.pumpWidget(
      sized(
        PaneLayoutView(
          layout: layout,
          regionBuilder: (group) =>
              SizedBox.expand(key: ValueKey(group.activePaneId)),
        ),
      ),
    );

    // 0.75 / 0.25 of the 800 that is left after the divider.
    const usable = 800 - kPaneDividerThickness;
    expect(
      tester.getSize(find.byKey(const ValueKey('a'))).width,
      closeTo(usable * 0.75, 1),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('b'))).width,
      closeTo(usable * 0.25, 1),
    );
  });

  testWidgets('a vertical split stacks its panes', (tester) async {
    await tester.pumpWidget(
      sized(
        PaneLayoutView(
          layout: PaneLayout.single(
            'a',
          ).split('a', SplitAxis.vertical, 'b', 's1'),
          regionBuilder: (group) =>
              SizedBox.expand(key: ValueKey(group.activePaneId)),
        ),
      ),
    );

    final top = tester.getRect(find.byKey(const ValueKey('a')));
    final bottom = tester.getRect(find.byKey(const ValueKey('b')));
    expect(top.width, 800);
    expect(bottom.top, greaterThanOrEqualTo(top.bottom));
  });

  testWidgets('dragging a divider reports a resize for that split', (
    tester,
  ) async {
    final resizes = <(String, int)>[];

    await tester.pumpWidget(
      sized(
        PaneLayoutView(
          layout: PaneLayout.single(
            'a',
          ).split('a', SplitAxis.horizontal, 'b', 's1'),
          regionBuilder: (group) =>
              SizedBox.expand(key: ValueKey(group.activePaneId)),
          onResize: (splitId, index, delta) => resizes.add((splitId, index)),
        ),
      ),
    );

    await tester.drag(find.byType(PaneDivider), const Offset(40, 0));
    await tester.pump();

    expect(resizes, isNotEmpty);
    expect(resizes.first, ('s1', 0));
  });

  /// The report was "resizing doesn't work as expected", with a wide, short
  /// pane. `PaneLayout.resize` takes a share of **one split**, so the pixels
  /// the pointer moved mean nothing until they are divided by the extent that
  /// split was given — along the axis it divides, and no other. Dividing by
  /// anything else makes the divider trail the pointer by exactly the ratio of
  /// the two, which in a 1440x560 window is a top/bottom divider moving 36 px
  /// for every 100 the mouse does.
  group('a divider drag is a share of its own split', () {
    testWidgets('a horizontal split measures across, not down', (tester) async {
      final deltas = <double>[];

      await tester.pumpWidget(
        sized(
          PaneLayoutView(
            layout: PaneLayout.single(
              'a',
            ).split('a', SplitAxis.horizontal, 'b', 's1'),
            regionBuilder: (group) =>
                SizedBox.expand(key: ValueKey(group.activePaneId)),
            onResize: (splitId, index, delta) => deltas.add(delta),
          ),
        ),
      );

      await tester.drag(find.byType(PaneDivider), const Offset(40, 0));
      await tester.pump();

      // 800 wide, less the one divider the two panes share.
      expect(
        deltas.fold(0.0, (sum, delta) => sum + delta),
        closeTo(40 / (800 - kPaneDividerThickness), 1e-3),
      );
    });

    testWidgets('a vertical split measures down, not across', (tester) async {
      final deltas = <double>[];

      await tester.pumpWidget(
        sized(
          PaneLayoutView(
            layout: PaneLayout.single(
              'a',
            ).split('a', SplitAxis.vertical, 'b', 's1'),
            regionBuilder: (group) =>
                SizedBox.expand(key: ValueKey(group.activePaneId)),
            onResize: (splitId, index, delta) => deltas.add(delta),
          ),
        ),
      );

      await tester.drag(find.byType(PaneDivider), const Offset(0, 40));
      await tester.pump();

      // 400 tall — the box's *short* side, which is the whole point.
      expect(
        deltas.fold(0.0, (sum, delta) => sum + delta),
        closeTo(40 / (400 - kPaneDividerThickness), 1e-3),
      );
    });

    testWidgets('a nested split measures its own room, not the whole view', (
      tester,
    ) async {
      final deltas = <double>[];
      // 's3' divides the bottom-right quarter, so it is 396 wide inside a view
      // that is 800 wide: half of the width, and the half is what counts.
      final layout = PaneLayout.single('a')
          .split('a', SplitAxis.horizontal, 'b', 's1')
          .split('b', SplitAxis.vertical, 'c', 's2')
          .split('c', SplitAxis.horizontal, 'd', 's3');

      await tester.pumpWidget(
        sized(
          PaneLayoutView(
            layout: layout,
            regionBuilder: (group) =>
                SizedBox.expand(key: ValueKey(group.activePaneId)),
            onResize: (splitId, index, delta) {
              if (splitId == 's3') deltas.add(delta);
            },
          ),
        ),
      );

      final inner = find.byWidgetPredicate(
        (widget) => widget is PaneDivider && widget.axis == SplitAxis.horizontal,
      );
      await tester.drag(inner.last, const Offset(40, 0));
      await tester.pump();

      const room = (800 - kPaneDividerThickness) / 2 - kPaneDividerThickness;
      expect(
        deltas.fold(0.0, (sum, delta) => sum + delta),
        closeTo(40 / room, 1e-3),
      );
    });
  });
}
