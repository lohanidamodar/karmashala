import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala_checkpoints/store.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/karmashala_host.dart' show DaemonCheckpoints;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'checkpoint_fixtures.dart';

/// When a turn becomes a checkpoint, at the server: from the hooks of a row
/// it does not hold, and from its own status for a row it does.
void main() {
  late CheckpointWorld w;

  setUp(() async => w = await CheckpointWorld.create());
  tearDown(() => w.close());

  /// Makes the hub's tree move, so a capture has something to record.
  var edits = 0;
  void touchHub() => File(
    p.join(w.hub, 'README.md'),
  ).writeAsStringSync('hub\nedit ${++edits}\n');

  group('a row this server does not hold, by its hooks', () {
    test('a turn is checkpointed as it starts and as it ends', () async {
      await w.hook('UserPromptSubmit', {'prompt': 'Fix the login redirect'});
      await w.settle();
      touchHub();
      await w.hook('Stop');
      await w.settle();
      expect(w.reasons(), ['turnStart', 'turn']);
      expect([for (final c in w.rows()) c.turn], [1, 1]);
      expect(w.rows().first.prompt, 'Fix the login redirect');
      expect(w.rows().last.prompt, 'Fix the login redirect');
      expect(
        w.told.whereType<CheckpointRecorded>().map((c) => c.checkpoint.id),
        [for (final c in w.rows()) c.id],
        reason: 'every row reaches every client as it is written',
      );
    }, skip: hasGit ? false : 'git is not on PATH');

    test('a turn that ends in an API error is still a turn', () async {
      await w.hook('UserPromptSubmit', {'prompt': 'x'});
      await w.settle();
      touchHub();
      await w.hook('StopFailure', {'error': 'rate_limit'});
      await w.settle();
      expect(w.reasons(), ['turnStart', 'turn']);
    }, skip: hasGit ? false : 'git is not on PATH');

    test('two hooks back to back still make a turn', () async {
      final start = w.hook('UserPromptSubmit', {'prompt': 'short'});
      final stop = w.hook('Stop');
      await Future.wait([start, stop]);
      await w.settle();
      expect(w.reasons(), ['turnStart'], reason: 'an unmoved tree is one row');
      expect(w.log.where((l) => l.contains('failed')), isEmpty);
    }, skip: hasGit ? false : 'git is not on PATH');

    test('an approval mid-turn does not end the turn', () async {
      await w.hook('UserPromptSubmit', {'prompt': 'x'});
      await w.hook('Notification', {
        'notification_type': 'permission_prompt',
        'message': 'Claude needs your permission to use Bash',
      });
      await w.hook('PostToolUse', {'tool_name': 'Bash'});
      await w.settle();
      expect(w.reasons(), ['turnStart']);
      touchHub();
      await w.hook('Stop');
      await w.settle();
      expect(w.reasons(), ['turnStart', 'turn']);
    }, skip: hasGit ? false : 'git is not on PATH');

    test(
      'turns are numbered, and a turn no hook announced has no prompt',
      () async {
        await w.turn(prompt: 'Fix the login redirect');
        // A turn that changes nothing writes nothing, and still uses its number.
        await w.turn(prompt: 'Look around');
        touchHub();
        await w.hook('UserPromptSubmit');
        await w.settle();
        touchHub();
        await w.hook('Stop');
        await w.settle();
        expect(
          [for (final c in w.rows()) '${c.reason.name}:${c.turn}'],
          ['turnStart:1', 'turnStart:3', 'turn:3'],
        );
        expect(w.rows().first.prompt, 'Fix the login redirect');
        expect(w.rows().last.prompt, isNull);
      },
      skip: hasGit ? false : 'git is not on PATH',
    );

    test('a restarted server continues the numbering from the store', () async {
      await w.turn();
      touchHub();
      await w.turn();
      final first = [for (final c in w.rows()) c.turn];
      await w.checkpoints.close();
      final again = restarted(w);
      addTearDown(again.close);
      touchHub();
      await again.hook(w.hookEvent('UserPromptSubmit', {'prompt': 'again'}));
      await again.recorder.settled('s1');
      await again.recorder.queued('s1', () async {});
      final turns = [for (final c in w.rows()) c.turn];
      expect(turns.sublist(0, first.length), first);
      expect(turns.last, (first.last ?? 0) + 1);
    }, skip: hasGit ? false : 'git is not on PATH');

    test('a hook for a conversation no row has records nothing', () async {
      await w.hook('UserPromptSubmit', {'prompt': 'x'}, 'someone-else');
      await w.hook('Stop', const {}, 'someone-else');
      await w.settle();
      expect(w.rows(), isEmpty);
    }, skip: hasGit ? false : 'git is not on PATH');

    test(
      'a failed capture is said once, and the next turn is recorded',
      () async {
        w.runners.failAdd = true;
        await w.turn();
        expect(w.rows(), isEmpty);
        expect(
          w.log.where((l) => l.contains('no checkpoint for session s1')),
          hasLength(1),
          reason: 'logged once, not once per edge',
        );
        expect(
          (await w.ask(const CheckpointSkips()))['s1'],
          contains('failed'),
        );
        w.runners.failAdd = false;
        touchHub();
        await w.turn();
        expect(w.reasons(), ['turnStart'], reason: 'nothing moved after it');
        expect(
          w.told.whereType<CheckpointSkipChanged>().last.reason,
          isNull,
          reason: 'a capture that reached git clears the reason',
        );
        expect(await w.ask(const CheckpointSkips()), isEmpty);
      },
      skip: hasGit ? false : 'git is not on PATH',
    );
  });

  group('a row this server holds, by its own status', () {
    setUp(() => w.held.add('s1'));

    test('its status moves make the turn; its hooks do not', () async {
      await w.hook('UserPromptSubmit', {'prompt': 'Held prompt'});
      await w.hook('Stop');
      await w.settle();
      expect(w.rows(), isEmpty, reason: 'a held row moves by the daemon');

      await w.hook('UserPromptSubmit', {'prompt': 'Held prompt'});
      w.status('s1', AgentActivityStatus.working);
      await w.settle();
      touchHub();
      w.status('s1', AgentActivityStatus.awaitingApproval);
      w.status('s1', AgentActivityStatus.working);
      w.status('s1', AgentActivityStatus.idle);
      await w.settle();
      expect(w.reasons(), ['turnStart', 'turn']);
      expect(w.rows().first.prompt, 'Held prompt', reason: 'hints still read');
    }, skip: hasGit ? false : 'git is not on PATH');

    test(
      'a held pane is named by its header, whatever its conversation',
      () async {
        w.addSession('s2', workingDirectory: w.hub);
        w.held.add('s2');
        await w.hook(
          'UserPromptSubmit',
          {'prompt': 'From the pane'},
          'fresh-conversation',
          's2',
        );
        w.status('s2', AgentActivityStatus.working);
        await w.settle('s2');
        expect(w.rows('s2').single.prompt, 'From the pane');
      },
      skip: hasGit ? false : 'git is not on PATH',
    );
  });

  group('what is not checkpointed, and why the panel is told', () {
    test('a session with no repository says so', () async {
      w.addSession('gone', repositoryId: 'nope', conversation: 'cli-9');
      await w.turn(conversation: 'cli-9');
      expect(w.rows('gone'), isEmpty);
      expect(
        w.told.whereType<CheckpointSkipChanged>().single.reason,
        'it has no repository to checkpoint',
      );
      expect(
        (await w.ask(const CheckpointSkips()))['gone'],
        'it has no repository to checkpoint',
      );
      expect(
        w.log,
        contains(
          'no checkpoint for session gone: it has no repository to '
          'checkpoint',
        ),
      );
    });

    test('a session on an SSH host says why', () async {
      w.addSession('s3', repositoryId: 'r2', conversation: 'cli-3');
      await w.turn(conversation: 'cli-3');
      expect(w.rows('s3'), isEmpty);
      expect(
        (await w.ask(const CheckpointSkips()))['s3'],
        'checkpoints are not supported for repositories on build-box: they '
        'need a private git index this machine can write to',
      );
    });

    test('with automatic checkpoints off nothing is recorded, a manual '
        'capture still is, and turning them on needs no restart', () async {
      w.setSettings(const CheckpointSettings(automatic: false));
      await w.turn();
      expect(w.rows(), isEmpty);
      expect(
        (await w.ask(const CheckpointSkips()))['s1'],
        kAutomaticCheckpointsOff,
      );
      final manual = await w.ask(const CheckpointCapture('s1'));
      expect(manual?.reason, CheckpointReason.manual);

      w.setSettings(const CheckpointSettings());
      touchHub();
      await w.turn();
      expect(w.reasons(), ['manual', 'turnStart']);
      expect(await w.ask(const CheckpointSkips()), isEmpty);
    }, skip: hasGit ? false : 'git is not on PATH');
  });

  test(
    'a repository past its limit is pruned to it, in batches',
    () async {
      const keep = 3;
      w.setSettings(const CheckpointSettings(keepPerRepository: keep));
      // keep + slack (10) rows of the hub, each a real tree.
      final service = w.checkpoints.service;
      for (var i = 0; i < keep + checkpointPruneSlack(keep); i++) {
        touchHub();
        await service.capture(w.local(w.hub), sessionId: 's1');
      }
      touchHub();
      await w.turn();
      // 15 rows is past 3 and its slack: back to the newest 3.
      final kept = w.ofRepo(w.hub);
      expect(kept, hasLength(keep));
      expect(kept.last.reason, CheckpointReason.turnStart);
      expect(kept.first.parentCommitSha, isNull, reason: 'the chain restarts');
      expect(w.told.whereType<CheckpointsPruned>(), isNotEmpty);
      touchHub();
      await w.turn();
      expect(
        w.ofRepo(w.hub),
        hasLength(keep + 1),
        reason: 'within the slack nothing is re-committed',
      );
    },
    skip: hasGit ? false : 'git is not on PATH',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

/// A second recorder over the same store, as a restarted server builds one.
DaemonCheckpoints restarted(CheckpointWorld w) => DaemonCheckpoints(
  database: w.db,
  data: w.data,
  heldHere: w.held.contains,
  runnerFactory: w.runners,
  clock: () => w.at,
  newId: () => 'again${CheckpointDao(w.db).recent(limit: 1000).length}',
);
