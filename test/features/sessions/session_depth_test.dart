import 'package:chitragupta/src/features/sessions/domain/session_depth.dart';
import 'package:flutter_test/flutter_test.dart';

/// A parent chain as a map, so a test can build any shape including broken ones.
ParentLookup chain(Map<String, String?> parents) =>
    (id) => parents[id];

void main() {
  group('depth is walked, never stored', () {
    test('a session the user started is depth 0', () {
      expect(SessionDepth.forChildOf(null, chain({})).depth, 0);
      expect(SessionDepth.forChildOf(null, chain({})).isAllowed, isTrue);
    });

    test('a child of a root session is depth 1', () {
      final depth = SessionDepth.forChildOf('a', chain({'a': null}));
      expect(depth.depth, 1);
      expect(depth.isAllowed, isTrue);
    });

    test('a grandchild is depth 2 and still allowed', () {
      final depth = SessionDepth.forChildOf('b', chain({'b': 'a', 'a': null}));
      expect(depth.depth, 2);
      expect(depth.isAllowed, isTrue);
    });

    test('a great-grandchild is refused', () {
      final depth = SessionDepth.forChildOf(
        'c',
        chain({'c': 'b', 'b': 'a', 'a': null}),
      );
      expect(depth.depth, 3);
      expect(depth.outcome, SessionDepthOutcome.tooDeep);
      expect(depth.isAllowed, isFalse);
      expect(depth.refusal, contains('2 levels'));
    });

    test('the cap is dray\'s: spawned may spawn, its children may not', () {
      expect(SessionDepth.maxDepth, 2);
    });

    test('an unknown parent id reads as a root', () {
      // A parent that has been deleted orphans its children rather than making
      // them unspawnable — the row is gone, the chain simply ends there.
      final depth = SessionDepth.forChildOf('missing', chain({}));
      expect(depth.depth, 1);
      expect(depth.isAllowed, isTrue);
    });
  });

  group('the cycle guard fails the turn rather than hanging it', () {
    test('a session that is its own parent is refused, not walked forever', () {
      final depth = SessionDepth.forChildOf('a', chain({'a': 'a'}));
      expect(depth.outcome, SessionDepthOutcome.cycle);
      expect(depth.isAllowed, isFalse);
    });

    test('a longer cycle is refused too', () {
      final depth = SessionDepth.forChildOf(
        'a',
        chain({'a': 'b', 'b': 'c', 'c': 'a'}),
      );
      expect(depth.outcome, SessionDepthOutcome.cycle);
    });

    test('a cycle is never reported as a depth', () {
      // The distinction matters: a cycle read as depth 0 would let an unbounded
      // chain spawn freely, which is the opposite of what the guard is for.
      final depth = SessionDepth.forChildOf('a', chain({'a': 'a'}));
      expect(depth.isAllowed, isFalse);
      expect(depth.refusal, contains('does not terminate'));
    });

    test('a chain longer than MAX_WALK is treated as broken', () {
      // Acyclic but absurd. Walking it would be a slow way to reach the same
      // refusal the depth cap gives at level 3.
      final parents = <String, String?>{
        for (var i = 0; i < SessionDepth.maxWalk + 10; i++) 's$i': 's${i + 1}',
      };
      final depth = SessionDepth.forChildOf('s0', chain(parents));
      expect(depth.outcome, SessionDepthOutcome.cycle);
    });

    test('the guard is 64 links, as dray has it', () {
      expect(SessionDepth.maxWalk, 64);
    });
  });
}
