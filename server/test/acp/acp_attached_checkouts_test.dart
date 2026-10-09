import 'dart:io';

import 'package:karmashala_acp/karmashala_acp.dart'
    show AcpRpcError, JsonRpcErrorCodes;
import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_host/src/acp/acp_path_scope.dart';
import 'package:karmashala_host/src/acp/acp_runtimes.dart';
import 'package:karmashala_host/src/acp/acp_terminals.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_command_runner.dart';
import 'acp_fixture.dart';

/// A chat-form session that attaches a checkout outside its working folder
/// reaches it with `fs/*` and `terminal/*` from the next request, and loses
/// it on detach — read off the same `session_repositories` rows the
/// repositories bar and `session_checkout_attach` write.
void main() {
  late AppDatabase database;
  late Directory temp;
  late String scratch;
  late String far;

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    temp = Directory.systemTemp.createTempSync('acp_attached');
    scratch = p.join(temp.path, 'scratch');
    Directory(scratch).createSync();
    far = p.join(temp.path, 'far');
    Directory(far).createSync();
    File(p.join(far, 'a.txt')).writeAsStringSync('far away');
    database.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, '
      'path, created_at) VALUES (?, ?, ?, ?, ?, ?);',
      ['r-far', 'p1', 'far', 'local', far, '2026-10-09T00:00:00Z'],
    );
  });

  tearDown(() {
    database.close();
    temp.deleteSync(recursive: true);
  });

  AcpPathScope scope() => AcpPathScope(
    root: scratch,
    environmentId: 'local',
    checkouts: () => sessionCheckoutsIn(database)('s1'),
  );

  test('fs/read_text_file reaches a checkout once attached, and not after '
      'it is detached', () async {
    final target = p.join(far, 'a.txt');
    final process = FakeAcpProcess(
      FakeAcpAgent(
        turns: [
          FakeTurn([FakeStep.readFile(target)]),
          FakeTurn([FakeStep.readFile(target)]),
          FakeTurn([FakeStep.readFile(target)]),
        ],
      ),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: scratch,
      files: scope(),
    );
    await runtime.start();
    final links = SessionRepositoryDao(database);

    await runtime.send('Before the attach');
    await runtime.awaitTurn();
    links.link('s1', 'r-far');
    await runtime.send('After it');
    await runtime.awaitTurn();
    links.unlink('s1', 'r-far');
    await runtime.send('After the detach');
    await runtime.awaitTurn();

    expect(process.agent.readFileResults, ['far away']);
    expect(process.agent.fsErrors, hasLength(2));
    for (final refusal in process.agent.fsErrors) {
      expect((refusal as AcpRpcError).code, JsonRpcErrorCodes.invalidParams);
    }
    await runtime.stop();
  });

  test('an agent that takes additionalDirectories is told the attached '
      'checkouts at session/new; one that does not is told nothing', () async {
    SessionRepositoryDao(database).link('s1', 'r-far');
    for (final supports in [true, false]) {
      final process = FakeAcpProcess(
        FakeAcpAgent(turns: const [], supportsAdditionalDirectories: supports),
      );
      final runtime = runtimeOver(
        process,
        database: database,
        workingDirectory: scratch,
        files: scope(),
      );
      await runtime.start();
      final created = process.agent.newSessionParams.single;
      if (supports) {
        expect(created['additionalDirectories'], [far]);
      } else {
        expect(created.containsKey('additionalDirectories'), isFalse);
      }
      await runtime.stop();
    }
  });

  test('terminal/create runs in an attached checkout', () async {
    SessionRepositoryDao(database).link('s1', 'r-far');
    final runner = FakeCommandRunner(
      processFactory: (_) => FakeProcessHandle()..complete(0),
    );
    final terminals = AcpTerminals(
      start: runner.start,
      scope: scope(),
      environmentId: runner.environmentId,
      posix: true,
    );
    await terminals.handle('terminal/create', {
      'sessionId': 's',
      'command': 'ls',
      'cwd': far,
    });
    expect(runner.startRequests.single.workingDirectory?.path, far);
    await terminals.releaseAll();
  });
}
