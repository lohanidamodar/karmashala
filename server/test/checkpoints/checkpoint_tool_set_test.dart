import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala_checkpoints/store.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/mcp/tools/server_tools.dart';
import 'package:karmashala_session/events.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'app_checkpoint_schemas.dart';
import 'checkpoint_fixtures.dart';

/// `checkpoint_list`, `checkpoint_capture`, `checkpoint_diff`,
/// `checkpoint_restore`, run by the server: the app's schemas byte for byte,
/// its answers, and its errors in its words.
void main() {
  late CheckpointWorld w;
  late CheckpointToolSet tools;

  setUp(() async {
    w = await CheckpointWorld.create();
    tools = CheckpointToolSet(w.checkpoints);
  });
  tearDown(() => w.close());

  Future<Object?> call(
    String tool, [
    Map<String, dynamic> args = const {},
    String? caller = 's1',
  ]) => tools.call(tool, args, caller)!;

  void writeReadme(String text) =>
      File(p.join(w.hub, 'README.md')).writeAsStringSync(text);

  test('the schemas are the app\'s, byte for byte', () {
    expect(jsonEncode(tools.schemas), jsonEncode(appCheckpointToolSchemas));
    expect(ServerTools([tools]).serves('checkpoint_restore'), isTrue);
  });

  test('capture, list and diff answer as the app did', () async {
    final captured =
        await call('checkpoint_capture', {'label': 'kept'})
            as Map<String, dynamic>;
    expect(captured['captured'], isTrue);
    final json = captured['checkpoint'] as Map<String, Object?>;
    expect(json['sessionId'], 's1');
    expect(json['title'], 'kept');
    expect(json['reason'], 'manual');
    expect(json['repository'], w.hub);
    expect(json['environmentId'], 'local');

    final again = await call('checkpoint_capture') as Map<String, dynamic>;
    expect(again, {
      'captured': false,
      'reason':
          'Nothing has changed since the last checkpoint, or the session has '
          'no repository to checkpoint.',
    });

    writeReadme('hub\nmore\n');
    await call('checkpoint_capture');
    final list = await call('checkpoint_list') as List;
    expect(list, hasLength(2));
    expect((list.first as Map)['sequence'], 2, reason: 'newest first');
    expect((list.first as Map)['files'], [
      {
        'path': 'README.md',
        'status': 'modified',
        'additions': 1,
        'deletions': 0,
      },
    ]);
    expect(await call('checkpoint_list', {'limit': 1}), hasLength(1));
    expect(
      await call('checkpoint_list', const {}, null),
      hasLength(2),
      reason: 'no session: the most recent everywhere',
    );

    final diff =
        await call('checkpoint_diff', {'id': (list.first as Map)['id']})
            as Map<String, dynamic>;
    expect(diff['diff'], contains('+more'));
  }, skip: hasGit ? false : 'git is not on PATH');

  test('a labelled capture by an agent is attributed to it', () async {
    await call('checkpoint_capture', {'label': 'Green build'}, 's1');
    await Future<void>.delayed(Duration.zero);
    final decision = w.told.whereType<DecisionRecorded>().single.decision;
    expect(decision.decidedBy, 'an agent in session s1');
    expect(decision.recordedBySessionId, 's1');
    expect(decision.kind, DecisionKind.checkpointMarked);
  }, skip: hasGit ? false : 'git is not on PATH');

  test(
    'restore answers the app\'s shape, and a moved tree its words',
    () async {
      final taken =
          ((await call('checkpoint_capture') as Map)['checkpoint'] as Map)['id']
              as String;
      writeReadme('hub\nnewer\n');

      Object? thrown;
      try {
        await call('checkpoint_restore', {'id': taken});
      } on StateError catch (error) {
        thrown = error;
      }
      final message = (thrown! as StateError).message;
      expect(message, contains('The working tree has changed since the last'));
      final safety = latestCheckpointIn(CheckpointDao(w.db).forSession('s1'))!;
      expect(
        message,
        endsWith(
          'Nothing was changed. The current working tree is saved as '
          'checkpoint ${safety.id}.',
        ),
      );

      final done =
          await call('checkpoint_restore', {
                'id': taken,
                'confirm': true,
                'paths': ['README.md'],
              })
              as Map<String, dynamic>;
      expect(done['restored'], isTrue);
      expect(done['alreadyThere'], isFalse);
      expect((done['checkpoint'] as Map)['id'], taken);
      expect(done['files'], [
        {'path': 'README.md', 'status': 'modified'},
      ]);
      expect(done.containsKey('safetyCheckpointId'), isTrue);
      expect(File(p.join(w.hub, 'README.md')).readAsStringSync(), 'hub\n');
    },
    skip: hasGit ? false : 'git is not on PATH',
  );

  test('errors are the app\'s, in its words', () async {
    await expectLater(
      call('checkpoint_diff'),
      throwsA(
        isA<ArgumentError>().having((e) => e.message, 'm', 'id is required.'),
      ),
    );
    await expectLater(
      call('checkpoint_restore', {'id': '  '}),
      throwsA(
        isA<ArgumentError>().having((e) => e.message, 'm', 'id is required.'),
      ),
    );
    await expectLater(
      call('checkpoint_diff', {'id': 'nope'}),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'm',
          'No checkpoint with id nope.',
        ),
      ),
    );
    await expectLater(
      call('checkpoint_capture', const {}, null),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'm',
          'sessionId is required for checkpoint_capture when the caller is '
              'not itself a Karmashala session.',
        ),
      ),
    );
  });

  test('a checkout on an SSH host is refused in words', () async {
    final remote = CheckpointDao(w.db).insert(
      Checkpoint(
        id: 'remote1',
        sessionId: 's1',
        repository: const EnvironmentPath(
          environmentId: 'box',
          path: '/srv/app',
        ),
        sequence: 0,
        treeSha: 't',
        commitSha: 'c',
        parentCommitSha: null,
        headSha: null,
        reason: CheckpointReason.turn,
        createdAt: w.at,
      ),
    );
    await expectLater(
      call('checkpoint_diff', {'id': remote.id}),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'm',
          'Checkpoints are not supported for repositories on build-box: they '
              'need a private git index this machine can write to.',
        ),
      ),
    );
    expect(DataRefusalCode.invalid.name, 'invalid');
  });
}
