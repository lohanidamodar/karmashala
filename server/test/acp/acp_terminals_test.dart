import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala_acp/karmashala_acp.dart'
    show AcpRpcError, JsonRpcErrorCodes;
import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_host/src/acp/acp_path_scope.dart';
import 'package:karmashala_host/src/acp/acp_terminals.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_command_runner.dart';
import 'acp_fixture.dart';

/// `terminal/*`: an agent's commands run on the session's machine through its
/// runner, in the session's folder, with bounded output that the chat shows
/// under the tool call embedding it, and every one ends with the session.
void main() {
  late AppDatabase database;
  late Directory temp;

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    temp = Directory.systemTemp.createTempSync('acp_terminals_test');
  });

  tearDown(() {
    database.close();
    temp.deleteSync(recursive: true);
  });

  /// Terminals over [runner] in [temp], POSIX unless said otherwise.
  AcpTerminals terminalsOver(FakeCommandRunner runner, {bool posix = true}) =>
      AcpTerminals(
        start: runner.start,
        scope: AcpPathScope(root: temp.path),
        environmentId: runner.environmentId,
        posix: posix,
      );

  /// A process that prints [lines] and exits [code] once [after] has passed.
  FakeCommandRunner scripted(
    List<String> lines, {
    int code = 0,
    Duration after = const Duration(milliseconds: 30),
    List<FakeProcessHandle>? started,
  }) => FakeCommandRunner(
    processFactory: (_) {
      final handle = FakeProcessHandle();
      started?.add(handle);
      Timer(after, () {
        lines.forEach(handle.emitStdout);
        handle.complete(code);
      });
      return handle;
    },
  );

  Map<String, Object?> toolJson(String toolCallId) {
    for (final row in SessionMessageDao(database).listAfter('s1')) {
      final json = row.toolJson;
      if (json == null) continue;
      final tool = (jsonDecode(json) as Map).cast<String, Object?>();
      if (tool['toolCallId'] == toolCallId) return tool;
    }
    fail('no tool row for $toolCallId');
  }

  test('the capability is advertised only with terminals', () async {
    final process = FakeAcpProcess(FakeAcpAgent());
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      terminals: terminalsOver(FakeCommandRunner()),
    );
    await runtime.start();
    expect(
      (process.agent.initializeParams!['clientCapabilities'] as Map)['terminal'],
      isTrue,
    );
    await runtime.stop();
  });

  test('a command line runs in the session folder through the shell; its '
      'output, exit and the tool row all say what happened', () async {
    final runner = scripted(['ok 1', 'ok 2'], code: 3);
    final process = FakeAcpProcess(
      FakeAcpAgent(
        turns: const [
          FakeTurn([
            FakeStep.terminal(
              toolCallId: 'c1',
              command: 'npm test',
              env: {'CI': '1'},
            ),
          ]),
        ],
      ),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      terminals: terminalsOver(runner),
    );
    await runtime.start();
    await runtime.send('test it');
    await runtime.awaitTurn();

    final request = runner.startRequests.single;
    expect(request.executable, 'sh');
    expect(request.arguments, ['-c', 'npm test']);
    expect(request.workingDirectory!.path, temp.path);
    expect(request.environment, {'CI': '1'});

    final agent = process.agent;
    expect(agent.terminalErrors, isEmpty);
    expect(agent.terminalExits.single, {'exitCode': 3, 'signal': null});
    expect(agent.terminalOutputs.single['output'], 'ok 1\nok 2');
    expect(agent.terminalOutputs.single['truncated'], isFalse);
    expect(
      (agent.terminalOutputs.single['exitStatus'] as Map)['exitCode'],
      3,
    );

    await pump();
    final terminal = (toolJson('c1')['content'] as List).single as Map;
    expect(terminal['type'], 'terminal');
    expect(terminal['output'], 'ok 1\nok 2');
    expect(terminal['exitCode'], 3);
    await runtime.stop();
  });

  test('the output shows under its tool call while the command still runs',
      () async {
    final started = <FakeProcessHandle>[];
    final runner = FakeCommandRunner(
      processFactory: (_) {
        final handle = FakeProcessHandle();
        started.add(handle);
        return handle;
      },
    );
    final process = FakeAcpProcess(
      FakeAcpAgent(
        turns: const [
          FakeTurn([FakeStep.terminal(toolCallId: 'c1', command: 'make')]),
        ],
      ),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      terminals: terminalsOver(runner),
    );
    await runtime.start();
    await runtime.send('build');
    while (started.isEmpty) {
      await pump();
    }
    await pump();
    started.single.emitStdout('compiling…');
    await settle(const Duration(milliseconds: 80));
    final live = (toolJson('c1')['content'] as List).single as Map;
    expect(live['output'], 'compiling…');
    expect(live.containsKey('exitCode'), isFalse);

    started.single.complete(0);
    await runtime.awaitTurn();
    await runtime.stop();
  });

  test('a command with its arguments runs as given', () async {
    final runner = scripted(const []);
    final terminals = terminalsOver(runner);
    await terminals.handle('terminal/create', {
      'sessionId': 's',
      'command': 'git',
      'args': ['status', '--short'],
    });
    final direct = runner.startRequests.single;
    expect(direct.executable, 'git');
    expect(direct.arguments, ['status', '--short']);
    await terminals.releaseAll();
  });

  test('a working directory outside the session folder is refused, and '
      'nothing is started', () async {
    final runner = scripted(const []);
    final terminals = terminalsOver(runner);
    await expectLater(
      terminals.handle('terminal/create', {
        'sessionId': 's',
        'command': 'ls',
        'cwd': p.dirname(temp.path),
      }),
      throwsA(
        isA<AcpRpcError>().having(
          (e) => e.code,
          'code',
          JsonRpcErrorCodes.invalidParams,
        ),
      ),
    );
    expect(runner.startRequests, isEmpty);
  });

  test('output past the limit keeps its end, cut on a character', () async {
    final runner = scripted(['ééééé', 'abcdef']);
    final terminals = terminalsOver(runner);
    final created = await terminals.handle('terminal/create', {
      'sessionId': 's',
      'command': 'x',
      'outputByteLimit': 10,
    }) as Map;
    final id = created['terminalId'] as String;
    await terminals.handle('terminal/wait_for_exit', {
      'sessionId': 's',
      'terminalId': id,
    });
    final output = await terminals.handle('terminal/output', {
      'sessionId': 's',
      'terminalId': id,
    }) as Map;
    expect(output['truncated'], isTrue);
    final text = output['output'] as String;
    expect(utf8.encode(text).length, lessThanOrEqualTo(10));
    expect(text, endsWith('\nabcdef'));
    expect(text.contains('�'), isFalse, reason: 'cut mid-character');
    await terminals.releaseAll();
  });

  test('kill ends the command and keeps its output; release forgets it',
      () async {
    final started = <FakeProcessHandle>[];
    final runner = FakeCommandRunner(
      processFactory: (_) {
        final handle = FakeProcessHandle();
        started.add(handle);
        return handle;
      },
    );
    final terminals = terminalsOver(runner);
    final id = ((await terminals.handle('terminal/create', {
      'sessionId': 's',
      'command': 'sleep',
      'args': ['100'],
    })) as Map)['terminalId'] as String;
    started.single.emitStdout('waiting');
    await pump();
    final ids = {'sessionId': 's', 'terminalId': id};

    await terminals.handle('terminal/kill', ids);
    expect(started.single.killed, isTrue);
    expect(await terminals.handle('terminal/wait_for_exit', ids), {
      'exitCode': 137,
      'signal': null,
    });
    expect(
      ((await terminals.handle('terminal/output', ids)) as Map)['output'],
      'waiting',
    );

    await terminals.handle('terminal/release', ids);
    await expectLater(
      terminals.handle('terminal/release', ids),
      throwsA(isA<AcpRpcError>()),
    );
    expect(terminals.snapshot(id)?.output, 'waiting');
  });

  test('a command still running when the session stops is killed with it',
      () async {
    final started = <FakeProcessHandle>[];
    final runner = FakeCommandRunner(
      processFactory: (_) {
        final handle = FakeProcessHandle();
        started.add(handle);
        return handle;
      },
    );
    final process = FakeAcpProcess(
      FakeAcpAgent(
        turns: const [
          FakeTurn([FakeStep.terminal(toolCallId: 'c1', command: 'serve')]),
        ],
      ),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      terminals: terminalsOver(runner),
    );
    await runtime.start();
    await runtime.send('serve it');
    while (started.isEmpty) {
      await pump();
    }
    started.single.emitStdout('listening on 8080');
    await pump();

    await runtime.stop();
    expect(started.single.killed, isTrue);
    final terminal = (toolJson('c1')['content'] as List).single as Map;
    expect(terminal['output'], 'listening on 8080');
  });

  test('an unknown terminal is refused in words', () async {
    final terminals = terminalsOver(FakeCommandRunner());
    await expectLater(
      terminals.handle('terminal/output', {
        'sessionId': 's',
        'terminalId': 'term-9',
      }),
      throwsA(
        isA<AcpRpcError>().having((e) => e.message, 'message', contains('term-9')),
      ),
    );
  });
}
