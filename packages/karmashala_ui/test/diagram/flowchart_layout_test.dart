import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/diagrams.dart';

void main() {
  FlowchartLayout layout(String source) {
    final chart = parseMermaid(source) as MermaidFlowchart;
    return layoutFlowchart(chart, {
      for (final n in chart.nodes) n.id: const Size(60, 30),
    });
  }

  test('top-down puts each rank below the last', () {
    final l = layout('graph TD\n A --> B --> C');
    expect(l.nodes['A']!.center.dy, lessThan(l.nodes['B']!.center.dy));
    expect(l.nodes['B']!.center.dy, lessThan(l.nodes['C']!.center.dy));
    expect(l.nodes['A']!.center.dx, closeTo(l.nodes['C']!.center.dx, 0.1));
  });

  test('left-right puts each rank to the right; right-left mirrors it', () {
    final lr = layout('graph LR\n A --> B');
    expect(lr.nodes['A']!.center.dx, lessThan(lr.nodes['B']!.center.dx));
    final rl = layout('graph RL\n A --> B');
    expect(rl.nodes['A']!.center.dx, greaterThan(rl.nodes['B']!.center.dx));
    final bt = layout('graph BT\n A --> B');
    expect(bt.nodes['A']!.center.dy, greaterThan(bt.nodes['B']!.center.dy));
  });

  test('nodes in one rank do not overlap', () {
    final l = layout('graph TD\n A --> B & C & D');
    final rank = [l.nodes['B']!, l.nodes['C']!, l.nodes['D']!];
    for (var i = 0; i < rank.length; i++) {
      for (var j = i + 1; j < rank.length; j++) {
        expect(rank[i].overlaps(rank[j]), isFalse);
      }
    }
  });

  test('a cycle is drawn, not looped on forever', () {
    final l = layout('graph TD\n A --> B --> C --> A\n C --> C');
    expect(l.nodes, hasLength(3));
    expect(l.edges, hasLength(4));
  });

  test('an edge spanning ranks bends between them', () {
    final l = layout('graph TD\n A --> B --> C\n A --> C');
    expect(l.edges[2].length, greaterThan(2));
  });

  test('edges start and end on the node borders', () {
    final l = layout('graph TD\n A --> B');
    final route = l.edges.single;
    expect(route.first.dy, closeTo(l.nodes['A']!.bottom, 0.5));
    expect(route.last.dy, closeTo(l.nodes['B']!.top, 0.5));
  });

  test('everything fits the size it reports', () {
    final l = layout('graph LR\n A --> B & C --> D --> E\n B --> E');
    final bounds = Offset.zero & l.size;
    for (final box in l.nodes.values) {
      expect(bounds.inflate(0.5).contains(box.topLeft), isTrue);
      expect(bounds.inflate(0.5).contains(box.bottomRight), isTrue);
    }
  });
}
