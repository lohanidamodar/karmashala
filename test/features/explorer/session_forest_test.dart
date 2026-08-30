import 'package:chitragupta/src/features/explorer/application/session_forest.dart';
import 'package:chitragupta/src/features/sessions/domain/session.dart';
import 'package:chitragupta/src/features/sessions/domain/session_lineage.dart';
import 'package:chitragupta/src/features/sessions/domain/session_status.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

/// How a row arranges the sessions on it.
///
/// The rule that matters most is the refusal: a parent chain that does not
/// terminate is drawn as **unknown**, never as a tree. A lineage view that
/// invents a plausible root is worse than one that admits it cannot tell.
void main() {
  Session at(
    String id, {
    String? parent,
    SessionLink? link,
    int minutes = 0,
    String? title,
  }) => Session(
    id: id,
    repositoryId: 'r1',
    agentInstallationId: 'a1',
    title: title ?? id,
    useWorktree: false,
    status: SessionStatus.running,
    createdAt: testTime.add(Duration(minutes: minutes)),
    parentSessionId: parent,
    parentLink: link,
  );

  List<SessionNode> forest(
    List<Session> sessions, {
    Set<String> pinned = const {},
  }) => buildSessionForest(sessions, isPinned: pinned.contains);

  test('a session the user started has no parent and no glyph', () {
    final nodes = forest([at('a')]);
    expect(nodes.single.link, isNull);
    expect(nodes.single.lineageBroken, isFalse);
    expect(nodes.single.children, isEmpty);
  });

  test('a fork is drawn under the session it came from', () {
    final nodes = forest([
      at('parent', minutes: 0),
      at('child', parent: 'parent', link: SessionLink.fork, minutes: 5),
    ]);

    expect(nodes.length, 1, reason: 'the child is not also a top-level row');
    expect(nodes.single.session.id, 'parent');
    expect(nodes.single.children.single.session.id, 'child');
    expect(nodes.single.children.single.link, SessionLink.fork);
  });

  test('a parent with no stated reason reads as a spawn', () {
    // Every row parented before schema v13 is one of these, and the launcher
    // stamps the same default.
    final nodes = forest([at('p'), at('c', parent: 'p')]);
    expect(nodes.single.children.single.link, SessionLink.spawn);
  });

  test('children are oldest first, whatever the top level is sorted by', () {
    final nodes = forest([
      at('p', minutes: 0),
      at('late', parent: 'p', minutes: 30),
      at('early', parent: 'p', minutes: 10),
    ]);
    expect(nodes.single.children.map((n) => n.session.id), [
      'early',
      'late',
    ], reason: 'the order the work happened in');
  });

  test('the top level is pinned first, then most recent', () {
    final nodes = forest(
      [
        at('old', minutes: 0),
        at('newest', minutes: 90),
        at('pinned', minutes: 10),
      ],
      pinned: {'pinned'},
    );
    expect(nodes.map((n) => n.session.id), ['pinned', 'newest', 'old']);
  });

  test('pinning a child never floats it above its parent', () {
    // The one thing the nesting exists to show would be the first casualty.
    final nodes = forest(
      [at('p', minutes: 0), at('c', parent: 'p', minutes: 5)],
      pinned: {'c'},
    );
    expect(nodes.single.session.id, 'p');
    expect(nodes.single.children.single.session.id, 'c');
  });

  test('a handoff whose parent is on another row keeps its glyph', () {
    // The child lives where the work moved to. Drawing it a second time under
    // its parent would say there are two sessions; saying nothing would lose
    // the fact that it came from somewhere.
    final nodes = forest([
      at('child', parent: 'elsewhere', link: SessionLink.handoff),
    ]);
    expect(nodes.single.link, SessionLink.handoff);
    expect(nodes.single.lineageBroken, isFalse);
  });

  test('a cycle is unknown lineage, not a tree', () {
    final nodes = forest([at('a', parent: 'b'), at('b', parent: 'a')]);

    // Both are drawn, both at the top, and both say the chain cannot be walked.
    expect(nodes.length, 2);
    expect(nodes.every((n) => n.lineageBroken), isTrue);
    expect(nodes.every((n) => n.children.isEmpty), isTrue);
  });

  test('a session that is its own parent is unknown lineage too', () {
    final nodes = forest([at('a', parent: 'a')]);
    expect(nodes.single.lineageBroken, isTrue);
    expect(nodes.single.children, isEmpty);
  });

  test('a chain longer than the guard is refused rather than walked', () {
    final chain = [
      for (var i = 0; i <= SessionLineage.maxWalk + 2; i++)
        at('s$i', parent: i == 0 ? null : 's${i - 1}', minutes: i),
    ];
    final nodes = forest(chain);

    // The root still nests what it can reach; the far end of the chain is where
    // the guard bites, and those rows say so instead of nesting on a walk that
    // never finished.
    final broken = nodes
        .expand((n) => n.flattened)
        .where((n) => n.lineageBroken)
        .toList();
    expect(broken, isNotEmpty);
    expect(
      nodes.expand((n) => n.flattened).length,
      chain.length,
      reason: 'nothing is dropped, however deep it is',
    );
  });

  test('three generations nest three deep', () {
    final nodes = forest([
      at('g0', minutes: 0),
      at('g1', parent: 'g0', link: SessionLink.handoff, minutes: 1),
      at('g2', parent: 'g1', link: SessionLink.fork, minutes: 2),
    ]);
    final g1 = nodes.single.children.single;
    expect(g1.session.id, 'g1');
    expect(g1.children.single.session.id, 'g2');
    expect(g1.children.single.link, SessionLink.fork);
  });

  test('an empty row is empty', () {
    expect(forest(const []), isEmpty);
  });
}
