import 'package:chitragupta/src/features/sessions/domain/session_lineage.dart';
import 'package:flutter_test/flutter_test.dart';

SessionLineageNode _node(String id, {SessionLink? link}) =>
    SessionLineageNode(sessionId: id, title: 'Session $id', link: link);

/// A lineage over a plain parent map, so the walk and its guard are exercised
/// without a database.
SessionLineage? _lineage(
  String id,
  Map<String, ({String? parent, SessionLink? link})> rows,
) => SessionLineage.build(
  id,
  lookup: (key) {
    final row = rows[key];
    if (row == null) return null;
    return (node: _node(key, link: row.link), parentId: row.parent);
  },
  children: (key) => [
    for (final entry in rows.entries)
      if (entry.value.parent == key) _node(entry.key, link: entry.value.link),
  ],
);

void main() {
  group('SessionLink', () {
    test('parses its own names and refuses anything else', () {
      expect(SessionLink.parse('handoff'), SessionLink.handoff);
      expect(SessionLink.parse('fork'), SessionLink.fork);
      expect(SessionLink.parse('spawn'), SessionLink.spawn);
      // A stored value we do not recognise reads as "we cannot tell", never as
      // a throw — the failure that made a fourth agent's rows unreadable in
      // Loop 30 — and never as a defaulted `spawn`, which would assert a
      // relationship nobody recorded.
      expect(SessionLink.parse('teleport'), isNull);
      expect(SessionLink.parse(null), isNull);
    });

    test('each kind reads as a sentence, child first', () {
      expect(SessionLink.handoff.phrase, 'handed off from');
      expect(SessionLink.fork.phrase, 'forked from');
      expect(SessionLink.spawn.phrase, 'spawned by');
    });
  });

  group('SessionLineage', () {
    test('a session the user started is a root with no link', () {
      final lineage = _lineage('a', {'a': (parent: null, link: null)})!;
      expect(lineage.isRoot, isTrue);
      expect(lineage.ancestors, isEmpty);
      expect(lineage.parent, isNull);
      expect(lineage.self.link, isNull);
      expect(lineage.chainBroken, isFalse);
    });

    test('ancestors come back root first, immediate parent last', () {
      final lineage = _lineage('c', {
        'a': (parent: null, link: null),
        'b': (parent: 'a', link: SessionLink.spawn),
        'c': (parent: 'b', link: SessionLink.fork),
      })!;
      expect(lineage.ancestors.map((n) => n.sessionId).toList(), ['a', 'b']);
      expect(lineage.parent!.sessionId, 'b');
      // The link belongs to the *child*: c was forked from b, and b was
      // spawned by a. Reading it off the parent would attribute each
      // relationship to the wrong session.
      expect(lineage.self.link, SessionLink.fork);
      expect(lineage.ancestors.last.link, SessionLink.spawn);
    });

    test('children come back for every kind of link, not just spawns', () {
      final lineage = _lineage('a', {
        'a': (parent: null, link: null),
        'b': (parent: 'a', link: SessionLink.handoff),
        'c': (parent: 'a', link: SessionLink.fork),
      })!;
      expect(lineage.children.map((n) => n.link).toList(), [
        SessionLink.handoff,
        SessionLink.fork,
      ]);
    });

    test('an orphan stops the walk without calling the chain broken', () {
      // Deleting a parent orphans its children rather than cascading (v10), so
      // a parent id naming nothing is an expected shape, not corruption.
      final lineage = _lineage('b', {
        'b': (parent: 'gone', link: SessionLink.handoff),
      })!;
      expect(lineage.ancestors, isEmpty);
      expect(lineage.chainBroken, isFalse);
      expect(lineage.self.link, SessionLink.handoff);
    });

    test('a cycle is reported, not walked forever', () {
      final lineage = _lineage('a', {
        'a': (parent: 'b', link: SessionLink.fork),
        'b': (parent: 'a', link: SessionLink.fork),
      })!;
      // The danger a cycle poses here is a hang inside the caller's turn, not a
      // wrong number — the same reasoning `SessionDepth` records.
      expect(lineage.chainBroken, isTrue);
    });

    test('a chain longer than the guard is reported as broken', () {
      final rows = <String, ({String? parent, SessionLink? link})>{};
      for (var i = 0; i <= SessionLineage.maxWalk + 5; i++) {
        rows['s$i'] = (
          parent: i == 0 ? null : 's${i - 1}',
          link: i == 0 ? null : SessionLink.fork,
        );
      }
      final deepest = 's${SessionLineage.maxWalk + 5}';
      expect(_lineage(deepest, rows)!.chainBroken, isTrue);
    });

    test('an unknown session has no lineage at all', () {
      expect(_lineage('nobody', const {}), isNull);
    });
  });
}
