import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'checkpoint_fixtures.dart';

/// **The server holds a tool for its checkpoint**: a `PreToolUse` is answered
/// only once the session's queued snapshots are taken — at most the hold, and
/// on expiry the turn's late before-turn snapshot says so on its own row.
/// No app is asked.
void main() {
  late CheckpointWorld w;

  tearDown(() => w.close());

  group('with the default hold', () {
    setUp(() async => w = await CheckpointWorld.create());

    test(
      'the hook holds the tool until the before-turn checkpoint is taken',
      () async {
        // No settle between them: the hold is the only thing between the turn
        // starting and the agent's first tool writing to the tree.
        unawaited(w.hook('UserPromptSubmit', {'prompt': 'Change it'}));
        await w.hook('PreToolUse', {
          'tool_name': 'Bash',
          'tool_input': {'command': 'ls'},
        });
        // The tool runs the moment the hook answers. The before-turn tree was
        // written before that; its row may be recorded just after.
        File(p.join(w.hub, 'written-by-the-tool.txt')).writeAsStringSync('x');
        await w.settle();
        expect(w.reasons(), ['turnStart']);
        final before = w.rows().single;
        expect(before.label, isNull, reason: 'the hold was met');
        expect(
          blobIn(
            before.repository.path,
            before.treeSha,
            'written-by-the-tool.txt',
          ),
          isEmpty,
          reason: 'the snapshot was taken before the tool ran',
        );
      },
      skip: hasGit ? false : 'git is not on PATH',
    );

    test(
      'a tool naming a nested clone waits for that clone\'s snapshot',
      () async {
        final file = p.join(w.app, 'main.txt');
        await w.hook('UserPromptSubmit', {'prompt': 'Change the app'});
        await w.hook('PreToolUse', w.edit(file));
        // The tool runs only once the hook has answered — by then the clone's
        // tree is written, whenever its row lands.
        File(file).writeAsStringSync('one\nTWO\nthree\n');
        await w.hook('Stop');
        await w.untilCheckpoints(w.app, 2);
        final nested = w.ofRepo(w.app);
        expect(blobIn(w.app, nested.first.treeSha, 'main.txt'), 'one\ntwo\n');
        expect(nested.first.label, isNull);
        expect(
          [for (final c in nested) c.reason],
          [CheckpointReason.turnStart, CheckpointReason.turn],
        );
      },
      skip: hasGit ? false : 'git is not on PATH',
    );

    test('a tool is held for the snapshots, never for the recording of the '
        'checkpoint before it', () async {
      // Recording a checkpoint (commit, ref, what changed) longer than the
      // hold: a tool held for it would be released with its hold expired.
      w.runners
        ..slowRecord = true
        ..delay = const Duration(seconds: 2);
      final file = p.join(w.app, 'main.txt');
      await w.hook('UserPromptSubmit', {'prompt': 'Change the app'});
      await w.hook('PreToolUse', w.edit(file));
      File(file).writeAsStringSync('one\nTWO\nthree\n');
      w.runners.slowRecord = false;
      await w.untilCheckpoints(w.app, 1);
      final nested = w.ofRepo(w.app);
      expect(blobIn(w.app, nested.first.treeSha, 'main.txt'), 'one\ntwo\n');
      expect(nested.first.label, isNull, reason: 'the hold was met');
      expect(w.log.where((l) => l.contains('released a tool')), isEmpty);
    }, skip: hasGit ? false : 'git is not on PATH');

    test('another event is answered at once', () async {
      w.runners
        ..slow = true
        ..delay = const Duration(milliseconds: 800);
      final took = Stopwatch()..start();
      await w.hook('UserPromptSubmit', {'prompt': 'x'});
      await w.hook('PostToolUse', {'tool_name': 'Bash'});
      expect(took.elapsed, lessThan(w.runners.delay));
      await w.settle();
    }, skip: hasGit ? false : 'git is not on PATH');
  });

  group('with a hold shorter than the capture', () {
    const hold = Duration(milliseconds: 250);
    setUp(() async => w = await CheckpointWorld.create(hold: hold));

    test(
      'a hold that expires before the snapshot leaves an undo point taken '
      'after the edit, and says so',
      () async {
        final file = p.join(w.app, 'main.txt');
        const edited = 'one\nTWO\nthree\n';

        await w.hook('UserPromptSubmit', {'prompt': 'Change the app'});
        await w.untilCheckpoints(w.hub, 1);
        expect(w.ofRepo(w.app), isEmpty, reason: 'nothing has named it yet');

        // The tool names a path in the nested clone; its snapshot is slower
        // than the hold, which gives up.
        w.runners
          ..slow = true
          ..delay = const Duration(milliseconds: 900);
        final heldFor = Stopwatch()..start();
        await w.hook('PreToolUse', w.edit(file));
        heldFor.stop();
        expect(heldFor.elapsed, greaterThanOrEqualTo(hold));
        expect(heldFor.elapsed, lessThan(w.runners.delay));
        expect(w.ofRepo(w.app), isEmpty, reason: 'released with no snapshot');
        expect(
          w.log.where((l) => l.contains('its hold expired')),
          hasLength(1),
        );

        // The tool is released and writes.
        File(file).writeAsStringSync(edited);
        File(p.join(w.hub, 'README.md')).writeAsStringSync('hub\nchanged\n');
        w.runners.slow = false;
        await w.hook('Stop');
        await w.untilCheckpoints(w.hub, 2);
        await w.settle();

        expect(
          [for (final c in w.ofRepo(w.hub)) c.reason],
          [CheckpointReason.turnStart, CheckpointReason.turn],
        );
        final nested = w.ofRepo(w.app);
        expect(
          [for (final c in nested) c.reason],
          [CheckpointReason.turnStart],
        );
        // The snapshot is of the edited tree: taken after the edit.
        expect(blobIn(w.app, nested.single.treeSha, 'main.txt'), edited);
        final restored = await w.ask(
          CheckpointRestore(nested.single.id, confirm: true),
        );
        expect(restored.outcomeOrThrow.alreadyThere, isTrue);
        // And the row says so, where the Restore button is.
        expect(nested.single.label, lateTurnStartLabel(1));
        expect(
          checkpointTitle(nested.single),
          'Before: Change the app — may already include its first edit',
        );
        // One expired hold casts no doubt on a row written before it.
        expect(w.ofRepo(w.hub).first.label, isNull);
        expect(
          checkpointTitle(w.ofRepo(w.hub).first),
          'Before: Change the app',
        );
      },
      skip: hasGit ? false : 'git is not on PATH',
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  group('over the hook endpoint', () {
    late HookServer endpoint;
    late List<AgentHookEvent> relayed;

    setUp(() async {
      w = await CheckpointWorld.create();
      relayed = [];
      endpoint = await HookServer.bind(
        // The server's hook path: the recorder first, then the relay; the
        // agent is answered when the recorder's hold is.
        onHook: (hook) {
          final held = w.checkpoints.hook(hook);
          relayed.add(hook);
          return held;
        },
        clock: () => w.at,
      );
    });
    tearDown(() => endpoint.close());

    Future<(int, Duration)> post(
      String event,
      Map<String, Object?> body,
    ) async {
      final client = HttpClient();
      final took = Stopwatch()..start();
      try {
        final request = await client.postUrl(
          Uri.parse(
            'http://127.0.0.1:${endpoint.port}/agent-hook'
            '?agent=${AgentIds.claudeCode}&event=$event',
          ),
        );
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer ${endpoint.token}',
        );
        request.write(
          jsonEncode({
            'session_id': 'cli-1',
            'hook_event_name': event,
            ...body,
          }),
        );
        final response = await request.close();
        await response.drain<void>();
        return (response.statusCode, took.elapsed);
      } finally {
        client.close();
      }
    }

    test(
      'a PreToolUse stays open until the capture it waits for is done',
      () async {
        w.runners
          ..slow = true
          ..delay = const Duration(milliseconds: 500);
        final prompt = post('UserPromptSubmit', {'prompt': 'Change it'});
        final (promptStatus, promptTook) = await prompt;
        expect(promptStatus, HttpStatus.ok);
        expect(promptTook, lessThan(w.runners.delay), reason: 'never held');

        final (status, took) = await post('PreToolUse', {
          'tool_name': 'Bash',
          'tool_input': {'command': 'ls'},
        });
        expect(status, HttpStatus.ok);
        expect(
          took,
          greaterThanOrEqualTo(w.runners.delay),
          reason: 'held while its snapshot ran `git add`',
        );
        expect(took, lessThan(kCheckpointHookHold));
        await w.settle();
        expect(w.reasons(), [
          'turnStart',
        ], reason: 'recorded once its tree was; log: ${w.log}');
        expect(w.rows().single.label, isNull);
        expect(relayed.map((h) => h.event), ['UserPromptSubmit', 'PreToolUse']);
      },
      skip: hasGit ? false : 'git is not on PATH',
    );

    test('a hook of no session here is answered at once', () async {
      final (status, took) = await post('PreToolUse', {
        'session_id': 'nobody',
        'tool_name': 'Bash',
      });
      expect(status, HttpStatus.ok);
      expect(took, lessThan(const Duration(milliseconds: 500)));
      expect(w.rows(), isEmpty);
    });
  });
}
