import 'package:agent_cli/process.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:test/test.dart';

/// **A checkpoint fork has two halves and only one of them is a rewind.** The
/// rules the fork tool refuses and reports by, whoever runs it.
const _repo = EnvironmentPath(environmentId: 'windows', path: r'C:\src\demo');
const _site = EnvironmentPath(environmentId: 'windows', path: r'C:\src\site');

Checkpoint _checkpoint({
  required String id,
  required int sequence,
  int? turn,
  CheckpointReason reason = CheckpointReason.turn,
  EnvironmentPath repository = _repo,
}) => Checkpoint(
  id: id,
  sessionId: 's1',
  repository: repository,
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

    List<String> ids(List<Checkpoint> found) => [for (final c in found) c.id];

    test('the turnStart of that turn wins over its end', () {
      expect(ids(checkpointsAtTurn(chain, 2)), ['c2']);
    });

    test('a turn with no turnStart and nothing before falls back to its '
        'earliest', () {
      expect(ids(checkpointsAtTurn(chain, 1)), ['c1']);
    });

    test('a turn nobody checkpointed is empty, not the nearest one', () {
      expect(checkpointsAtTurn(chain, 3), isEmpty);
      expect(checkpointsAtTurn(chain, 0), isEmpty);
    });

    test('every repository the turn touched gets its own checkpoint', () {
      final both = [
        _checkpoint(
          id: 'a1',
          sequence: 1,
          turn: 1,
          reason: CheckpointReason.turnStart,
        ),
        _checkpoint(
          id: 'b1',
          sequence: 2,
          turn: 1,
          reason: CheckpointReason.turnStart,
          repository: _site,
        ),
        _checkpoint(id: 'a2', sequence: 3, turn: 1),
        _checkpoint(id: 'b2', sequence: 4, turn: 1, repository: _site),
      ];
      expect(ids(checkpointsAtTurn(both, 1)), ['a1', 'b1']);
    });

    test('a repository unchanged as the turn began restores to its checkpoint '
        'before the turn, which is the tree the turn started on', () {
      // No turnStart is recorded for a tree identical to the last one.
      final both = [
        _checkpoint(id: 'b0', sequence: 1, turn: 1, repository: _site),
        _checkpoint(
          id: 'a1',
          sequence: 2,
          turn: 2,
          reason: CheckpointReason.turnStart,
        ),
        _checkpoint(id: 'a2', sequence: 3, turn: 2),
        _checkpoint(id: 'b2', sequence: 4, turn: 2, repository: _site),
      ];
      expect(ids(checkpointsAtTurn(both, 2)), ['a1', 'b0']);
    });

    test('the turns a refusal can name leave the unnumbered ones out', () {
      expect(forkableTurns(chain), [1, 2]);
      expect(forkableTurns(const <Checkpoint>[]), isEmpty);
    });
  });

  group('the answer states each half it delivered, and each it did not', () {
    final checkpoint = _checkpoint(id: 'c9', sequence: 9, turn: 4);
    final site = _checkpoint(
      id: 's9',
      sequence: 10,
      turn: 4,
      repository: _site,
    );

    test('a whole fork still reports the conversation as not rewound', () {
      final halves = checkpointForkHalves(
        route: 'native',
        repositories: [
          ForkedRepository(
            checkpoint,
            alreadyThere: false,
            restoredFiles: 3,
            undoCheckpointId: 'u1',
          ),
        ],
      );
      expect(halves.delivered, hasLength(2));
      expect(halves.delivered.first, contains('by the native route'));
      expect(halves.delivered.last, contains('checkpoint 9 (3 files)'));
      expect(halves.delivered.last, contains('checkpoint_restore u1'));
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
        repositories: [ForkedRepository(checkpoint, refusal: refusal)],
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
          repositories: [ForkedRepository(checkpoint, alreadyThere: true)],
        );
        expect(halves.delivered.last, contains('already matched checkpoint 9'));
        expect(halves.delivered.last, isNot(contains('0 files')));
      },
    );

    test('several repositories are each reported, by path, with their own '
        'way back, and one left alone says where and why', () {
      final halves = checkpointForkHalves(
        route: 'native',
        repositories: [
          ForkedRepository(
            checkpoint,
            alreadyThere: false,
            restoredFiles: 2,
            undoCheckpointId: 'u1',
          ),
          ForkedRepository(
            site,
            refusal: 'The files were left as they are: x.',
          ),
        ],
      );
      expect(halves.delivered, hasLength(2));
      expect(halves.delivered.last, contains(r'C:\src\demo'));
      expect(halves.delivered.last, contains('checkpoint_restore u1'));
      expect(halves.notDelivered, [
        kForkCarriesTheWholeConversation,
        r'C:\src\site: The files were left as they are: x.',
      ]);
    });

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
