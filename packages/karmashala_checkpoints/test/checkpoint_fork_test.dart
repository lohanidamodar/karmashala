import 'package:agent_cli/process.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:test/test.dart';

/// **A checkpoint fork has two halves and only one of them is a rewind.** The
/// rules the fork tool refuses and reports by, whoever runs it.
const _repo = EnvironmentPath(environmentId: 'windows', path: r'C:\src\demo');

Checkpoint _checkpoint({
  required String id,
  required int sequence,
  int? turn,
  CheckpointReason reason = CheckpointReason.turn,
}) => Checkpoint(
  id: id,
  sessionId: 's1',
  repository: _repo,
  sequence: sequence,
  treeSha: 'tree$sequence',
  commitSha: 'commit$sequence',
  parentCommitSha: null,
  headSha: 'head1',
  reason: reason,
  createdAt: DateTime.utc(2026, 9, 20),
  turn: turn,
);

void main() {
  group('the file half is refused rather than done unsafely', () {
    test('a checkout nobody else is in is restored', () {
      expect(
        checkpointForkFileRefusal(
          intoNewWorktree: false,
          unsupportedEnvironmentReason: null,
          otherSessionsInCheckout: const [],
        ),
        isNull,
      );
    });

    test('another session in the checkout refuses it, and is named', () {
      final refusal = checkpointForkFileRefusal(
        intoNewWorktree: false,
        unsupportedEnvironmentReason: null,
        otherSessionsInCheckout: const ['Nightly sweep'],
      );
      expect(refusal, contains('"Nightly sweep" is'));
      expect(refusal, isNot(contains('confirm')));
      expect(refusal, contains('newWorktree true'));
      expect(
        checkpointForkFileRefusal(
          intoNewWorktree: false,
          unsupportedEnvironmentReason: null,
          otherSessionsInCheckout: const ['a', 'b'],
        ),
        contains('2 other sessions are'),
      );
    });

    test('a new worktree gives the restore up, and says which it gave up', () {
      final refusal = checkpointForkFileRefusal(
        intoNewWorktree: true,
        unsupportedEnvironmentReason: null,
        otherSessionsInCheckout: const [],
      );
      expect(refusal, contains('fresh checkout of the branch'));
      expect(refusal, isNot(contains('working in this checkout')));
    });

    test('an environment that cannot be checkpointed is named first', () {
      expect(
        checkpointForkFileRefusal(
          intoNewWorktree: true,
          unsupportedEnvironmentReason:
              'checkpoints are not supported for repositories on box',
          otherSessionsInCheckout: const ['Nightly sweep'],
        ),
        contains('not supported for repositories on box'),
      );
    });

    test('every refusal opens by saying the files did not move', () {
      for (final refusal in <String?>[
        checkpointForkFileRefusal(
          intoNewWorktree: true,
          unsupportedEnvironmentReason: null,
          otherSessionsInCheckout: const [],
        ),
        checkpointForkFileRefusal(
          intoNewWorktree: false,
          unsupportedEnvironmentReason: null,
          otherSessionsInCheckout: const ['x'],
        ),
        checkpointForkFileRefusal(
          intoNewWorktree: false,
          unsupportedEnvironmentReason: 'nope',
          otherSessionsInCheckout: const [],
        ),
      ]) {
        expect(refusal, startsWith('The files were left as they are: '));
      }
    });
  });

  group('turn: n resolves to the state the turn began in', () {
    final chain = [
      _checkpoint(id: 'c1', sequence: 1, turn: 1),
      _checkpoint(
        id: 'c2',
        sequence: 2,
        turn: 2,
        reason: CheckpointReason.turnStart,
      ),
      _checkpoint(id: 'c3', sequence: 3, turn: 2),
      _checkpoint(id: 'c4', sequence: 4, reason: CheckpointReason.manual),
    ];

    test('the turnStart of that turn wins over its end', () {
      expect(checkpointAtTurn(chain, 2)?.id, 'c2');
    });

    test('a turn with no turnStart falls back to its earliest', () {
      expect(checkpointAtTurn(chain, 1)?.id, 'c1');
    });

    test('a turn nobody checkpointed is null, not the nearest one', () {
      expect(checkpointAtTurn(chain, 3), isNull);
      expect(checkpointAtTurn(chain, 0), isNull);
    });

    test('the turns a refusal can name leave the unnumbered ones out', () {
      expect(forkableTurns(chain), [1, 2]);
      expect(forkableTurns(const <Checkpoint>[]), isEmpty);
    });
  });

  group('the answer states each half it delivered, and each it did not', () {
    final checkpoint = _checkpoint(id: 'c9', sequence: 9, turn: 4);

    test('a whole fork still reports the conversation as not rewound', () {
      final halves = checkpointForkHalves(
        route: 'native',
        checkpoint: checkpoint,
        alreadyThere: false,
        restoredFiles: 3,
      );
      expect(halves.delivered, hasLength(2));
      expect(halves.delivered.first, contains('by the native route'));
      expect(halves.delivered.last, contains('checkpoint 9 (3 files)'));
      expect(halves.notDelivered, [kForkCarriesTheWholeConversation]);
    });

    test('a refused file half is in notDelivered, never absent', () {
      final refusal = checkpointForkFileRefusal(
        intoNewWorktree: true,
        unsupportedEnvironmentReason: null,
        otherSessionsInCheckout: const [],
      );
      final halves = checkpointForkHalves(
        route: 'handoff',
        checkpoint: checkpoint,
        fileRefusal: refusal,
      );
      expect(halves.delivered, hasLength(1));
      expect(halves.delivered.single, isNot(contains('working tree')));
      expect(halves.notDelivered, [kForkCarriesTheWholeConversation, refusal]);
    });

    test(
      'a tree that already matched is delivered, and says it wrote none',
      () {
        final halves = checkpointForkHalves(
          route: 'native',
          checkpoint: checkpoint,
          alreadyThere: true,
        );
        expect(halves.delivered.last, contains('already matched checkpoint 9'));
        expect(halves.delivered.last, isNot(contains('0 files')));
      },
    );

    test('the conversation sentence says what no CLI can do', () {
      expect(
        kForkCarriesTheWholeConversation,
        contains('carried whole, not rewound'),
      );
      expect(
        kForkCarriesTheWholeConversation,
        contains('no agent CLI here can resume a conversation part-way'),
      );
    });
  });
}
