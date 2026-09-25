import 'package:karmashala/src/features/mcp/mcp_tool_dispatcher.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/checkpoints/application/checkpoint_fork.dart';
import 'package:karmashala/src/features/checkpoints/domain/checkpoint.dart';

/// **A checkpoint fork has two halves and only one of them is a rewind.**
///
/// The files go back to the checkpoint; the conversation is carried whole,
/// because no CLI here can resume one at a turn. Everything below is about the
/// tool never claiming otherwise: the sentence it says instead, the three
/// reasons it declines the file half rather than doing it unsafely, and the
/// checkpoint `turn: n` actually resolves to.
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

Map<String, dynamic> _schema(String name) =>
    McpToolDispatcher.toolSchemas.firstWhere((s) => s['name'] == name);

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
        reason:
            'the ordinary case must go through, or the verb delivers nothing '
            'the plain fork does not',
      );
    });

    test('another session in the checkout refuses it, and is named', () {
      final refusal = checkpointForkFileRefusal(
        intoNewWorktree: false,
        unsupportedEnvironmentReason: null,
        otherSessionsInCheckout: const ['Nightly sweep'],
      );
      expect(refusal, contains('"Nightly sweep" is'));
      // Not "confirm to do it anyway": the caller's confirmation is not the
      // other session's consent, so this refusal has no escape hatch.
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
      // The honest half: a fresh worktree is a checkout of the branch, and a
      // caller who reads "forked from checkpoint 9" would assume otherwise.
      expect(refusal, contains('fresh checkout of the branch'));
      expect(refusal, isNot(contains('working in this checkout')));
    });

    test('an environment that cannot be checkpointed is named first', () {
      // Precedence matters: a repository on SSH cannot be restored whatever
      // else is true, and reporting the worktree reason would be a wrong one.
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
      _checkpoint(
        id: 'c1',
        sequence: 1,
        turn: 1,
        reason: CheckpointReason.turn,
      ),
      _checkpoint(
        id: 'c2',
        sequence: 2,
        turn: 2,
        reason: CheckpointReason.turnStart,
      ),
      _checkpoint(
        id: 'c3',
        sequence: 3,
        turn: 2,
        reason: CheckpointReason.turn,
      ),
      _checkpoint(id: 'c4', sequence: 4, reason: CheckpointReason.manual),
    ];

    test('the turnStart of that turn wins over its end', () {
      expect(checkpointAtTurn(chain, 2)?.id, 'c2');
    });

    test('a turn with no turnStart falls back to its earliest', () {
      expect(checkpointAtTurn(chain, 1)?.id, 'c1');
    });

    test('a turn nobody checkpointed is null, not the nearest one', () {
      // The nearest is the tempting answer and the wrong one: forking from a
      // turn that was never recorded would restore somebody else's state.
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
      // Even the best case admits the half it cannot do. A `notDelivered`
      // that can come back empty would read as "this was a complete fork".
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
      expect(
        halves.delivered.single,
        isNot(contains('working tree')),
        reason: 'nothing was restored, so nothing may say a tree was',
      );
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
  });

  group('the tool says what it does not do', () {
    test('the conversation sentence is where the schema gets it', () {
      // One string, so a description promising a rewind cannot be written
      // while the code refuses to do one.
      expect(
        kForkCarriesTheWholeConversation,
        contains('carried whole, not rewound'),
      );
      expect(
        kForkCarriesTheWholeConversation,
        contains('no agent CLI here can resume a conversation part-way'),
      );
    });

    test('the schema names both halves and the file half\'s refusals', () {
      final description =
          _schema('session_fork_from_checkpoint')['description'] as String;
      expect(description, contains('TWO HALVES'));
      expect(description, contains('CONVERSATION IS CARRIED WHOLE'));
      expect(description, contains('DESTRUCTIVE'));
      expect(description, contains('another session is working in that '));
      expect(description, contains('"delivered" and '));
      expect(description, contains('"notDelivered"'));
      expect(description, contains('never claims a half it did not do'));
    });

    test(
      'it takes a checkpoint or a turn, and only the session is required',
      () {
        final input =
            _schema('session_fork_from_checkpoint')['inputSchema']
                as Map<String, dynamic>;
        expect(input['required'], ['sessionId']);
        expect(
          (input['properties'] as Map).keys,
          containsAll([
            'sessionId',
            'checkpointId',
            'turn',
            'instruction',
            'newWorktree',
            'confirm',
            'preview',
          ]),
        );
      },
    );

    test('it offers the same preview the other two fork verbs do', () {
      final preview =
          ((_schema('session_fork_from_checkpoint')['inputSchema']
                      as Map<String, dynamic>)['properties']
                  as Map<String, dynamic>)['preview']
              as Map<String, dynamic>;
      expect(preview['type'], 'boolean');
      expect(preview['description'], contains('without starting anything'));
      expect(preview['description'], contains('without touching a file'));
    });
  });
}
