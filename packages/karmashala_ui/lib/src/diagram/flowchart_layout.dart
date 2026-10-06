import 'dart:math' as math;
import 'dart:ui';

import 'mermaid_model.dart';

/// Where each node of a flowchart sits and the points each edge runs
/// through: a layered (Sugiyama-style) layout. Nodes are ranked by longest
/// path, an edge spanning ranks bends through a point in each rank between,
/// and each rank is ordered by its neighbours' average position to cut
/// crossings.
class FlowchartLayout {
  const FlowchartLayout(this.size, this.nodes, this.edges);

  final Size size;

  /// Each node's box, by id.
  final Map<String, Rect> nodes;

  /// Each edge's points from the source's border to the target's, in the
  /// order of [MermaidFlowchart.edges].
  final List<List<Offset>> edges;
}

const double _rankGap = 56;
const double _nodeGap = 28;
const double _bendWidth = 8;

FlowchartLayout layoutFlowchart(
  MermaidFlowchart chart,
  Map<String, Size> sizes,
) {
  final ids = [for (final n in chart.nodes) n.id];
  final index = {for (final (i, id) in ids.indexed) id: i};
  final horizontal =
      chart.direction == MermaidDirection.leftRight ||
      chart.direction == MermaidDirection.rightLeft;

  // Edges as ranks see them: a self-loop has no rank of its own, and a cycle
  // is broken by reversing each edge DFS finds pointing back.
  final forward = <(int, int)>[];
  final reversed = <int>{};
  final out = List.generate(ids.length, (_) => <int>[]);
  for (final e in chart.edges) {
    if (e.from == e.to) continue;
    out[index[e.from]!].add(index[e.to]!);
  }
  final state = List.filled(ids.length, 0);
  final back = <(int, int)>{};
  void visit(int v) {
    state[v] = 1;
    for (final w in out[v]) {
      if (state[w] == 1) {
        back.add((v, w));
      } else if (state[w] == 0) {
        visit(w);
      }
    }
    state[v] = 2;
  }

  for (var v = 0; v < ids.length; v++) {
    if (state[v] == 0) visit(v);
  }
  for (final (i, e) in chart.edges.indexed) {
    if (e.from == e.to) continue;
    final a = index[e.from]!;
    final b = index[e.to]!;
    if (back.contains((a, b))) {
      reversed.add(i);
      forward.add((b, a));
    } else {
      forward.add((a, b));
    }
  }

  // Longest-path ranks.
  final rank = List.filled(ids.length, 0);
  final incoming = List.filled(ids.length, 0);
  final next = List.generate(ids.length, (_) => <int>[]);
  for (final (a, b) in forward) {
    next[a].add(b);
    incoming[b]++;
  }
  final queue = [
    for (var v = 0; v < ids.length; v++)
      if (incoming[v] == 0) v,
  ];
  for (var q = 0; q < queue.length; q++) {
    final v = queue[q];
    for (final w in next[v]) {
      rank[w] = math.max(rank[w], rank[v] + 1);
      if (--incoming[w] == 0) queue.add(w);
    }
  }
  final rankCount = rank.isEmpty ? 1 : rank.reduce(math.max) + 1;

  // Each rank's members: real nodes, then one bend point per rank an edge
  // crosses. A bend is numbered past the real nodes.
  final members = List.generate(rankCount, (_) => <int>[]);
  for (var v = 0; v < ids.length; v++) {
    members[rank[v]].add(v);
  }
  final bendsOf = <int, List<int>>{};
  final bendRank = <int>[];
  final links = <(int, int)>[];
  for (final (i, e) in chart.edges.indexed) {
    if (e.from == e.to) continue;
    var a = index[e.from]!;
    var b = index[e.to]!;
    if (reversed.contains(i)) (a, b) = (b, a);
    final chain = <int>[];
    var previous = a;
    for (var r = rank[a] + 1; r < rank[b]; r++) {
      final bend = ids.length + bendRank.length;
      bendRank.add(r);
      members[r].add(bend);
      chain.add(bend);
      links.add((previous, bend));
      previous = bend;
    }
    links.add((previous, b));
    bendsOf[i] = chain;
  }
  final total = ids.length + bendRank.length;
  final up = List.generate(total, (_) => <int>[]);
  final down = List.generate(total, (_) => <int>[]);
  for (final (a, b) in links) {
    down[a].add(b);
    up[b].add(a);
  }

  // Barycentre sweeps, down then up, a few times.
  final position = List.filled(total, 0.0);
  void number() {
    for (final rankMembers in members) {
      for (final (i, v) in rankMembers.indexed) {
        position[v] = i.toDouble();
      }
    }
  }

  number();
  for (var pass = 0; pass < 4; pass++) {
    final downward = pass.isEven;
    final order = downward
        ? List.generate(rankCount, (r) => r)
        : List.generate(rankCount, (r) => rankCount - 1 - r);
    for (final r in order.skip(1)) {
      final neighbours = downward ? up : down;
      double centre(int v) {
        final around = neighbours[v];
        if (around.isEmpty) return position[v];
        return around.map((u) => position[u]).reduce((a, b) => a + b) /
            around.length;
      }

      final centres = {for (final v in members[r]) v: centre(v)};
      members[r].sort((a, b) {
        final c = centres[a]!.compareTo(centres[b]!);
        return c != 0 ? c : position[a].compareTo(position[b]);
      });
      for (final (i, v) in members[r].indexed) {
        position[v] = i.toDouble();
      }
    }
  }

  // Sizes along the rank (across) and between ranks (along).
  Size sizeOf(int v) => v < ids.length
      ? sizes[ids[v]] ?? const Size(80, 36)
      : const Size(_bendWidth, _bendWidth);
  double across(Size s) => horizontal ? s.height : s.width;
  double along(Size s) => horizontal ? s.width : s.height;

  final rankDepth = [
    for (final m in members)
      m.isEmpty ? 0.0 : m.map((v) => along(sizeOf(v))).reduce(math.max),
  ];
  final rankBreadth = [
    for (final m in members)
      m.isEmpty
          ? 0.0
          : m.map((v) => across(sizeOf(v))).reduce((a, b) => a + b) +
                _nodeGap * (m.length - 1),
  ];
  final breadth = rankBreadth.isEmpty ? 0.0 : rankBreadth.reduce(math.max);

  final centreOf = List.filled(total, Offset.zero);
  var depth = 0.0;
  for (var r = 0; r < rankCount; r++) {
    var cursor = (breadth - rankBreadth[r]) / 2;
    for (final v in members[r]) {
      final s = sizeOf(v);
      final a = cursor + across(s) / 2;
      final d = depth + rankDepth[r] / 2;
      centreOf[v] = horizontal ? Offset(d, a) : Offset(a, d);
      cursor += across(s) + _nodeGap;
    }
    depth += rankDepth[r] + _rankGap;
  }
  final extent = math.max(0.0, depth - _rankGap);
  var size = horizontal ? Size(extent, breadth) : Size(breadth, extent);

  Offset flip(Offset p) => switch (chart.direction) {
    MermaidDirection.bottomUp => Offset(p.dx, size.height - p.dy),
    MermaidDirection.rightLeft => Offset(size.width - p.dx, p.dy),
    _ => p,
  };

  final boxes = <String, Rect>{
    for (var v = 0; v < ids.length; v++)
      ids[v]: Rect.fromCenter(
        center: flip(centreOf[v]),
        width: sizeOf(v).width,
        height: sizeOf(v).height,
      ),
  };

  final routes = <List<Offset>>[];
  for (final (i, e) in chart.edges.indexed) {
    final from = boxes[e.from]!;
    final to = boxes[e.to]!;
    if (e.from == e.to) {
      final r = from;
      routes.add([
        r.topRight.translate(-r.width / 4, 0),
        r.topRight.translate(12, -14),
        r.centerRight.translate(12, 0),
        r.centerRight,
      ]);
      continue;
    }
    var middle = [for (final b in bendsOf[i]!) flip(centreOf[b])];
    if (reversed.contains(i)) middle = middle.reversed.toList();
    final firstTarget = middle.isEmpty ? to.center : middle.first;
    final lastSource = middle.isEmpty ? from.center : middle.last;
    routes.add([
      _border(from, firstTarget),
      ...middle,
      _border(to, lastSource),
    ]);
  }

  // Self-loops reach past the right edge.
  if (chart.edges.any((e) => e.from == e.to)) {
    size = Size(size.width + 16, size.height);
  }
  return FlowchartLayout(size, boxes, routes);
}

/// Where the line from [box]'s centre towards [towards] leaves the box.
Offset _border(Rect box, Offset towards) {
  final c = box.center;
  final d = towards - c;
  if (d.dx == 0 && d.dy == 0) return c;
  final sx = d.dx == 0 ? double.infinity : (box.width / 2) / d.dx.abs();
  final sy = d.dy == 0 ? double.infinity : (box.height / 2) / d.dy.abs();
  final s = math.min(sx, sy);
  return c + d * s;
}
