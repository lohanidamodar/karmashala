import 'dart:io';

import 'package:karmashala_acp/karmashala_acp.dart'
    show AvailableCommand, AvailableCommandsUpdate;
import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show SessionCommand, SessionCommandsChanged;
import 'package:karmashala_host/src/acp/acp_session_modes.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'acp_fixture.dart';

/// `available_commands_update`: the agent's slash commands are kept per
/// session on the server, told to every client as they change, greeted to
/// one that arrives later, and cleared when the agent is gone.
void main() {
  late AppDatabase database;
  late Directory temp;
  late _CommandsHost host;

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    temp = Directory.systemTemp.createTempSync('acp_commands_test');
    host = _CommandsHost();
  });

  tearDown(() {
    database.close();
    temp.deleteSync(recursive: true);
  });

  const review = AvailableCommand(
    name: 'review',
    description: 'Review the changes',
    inputHint: 'what to focus on',
  );
  const compact = AvailableCommand(
    name: 'compact',
    description: 'Compact the context',
  );

  test('commands the agent announces are told, kept and greeted', () async {
    final process = FakeAcpProcess(
      FakeAcpAgent(
        turns: [
          const FakeTurn([
            FakeStep.update(AvailableCommandsUpdate([review, compact])),
            FakeStep.message('Ready.'),
          ]),
          const FakeTurn([
            FakeStep.update(AvailableCommandsUpdate([compact])),
          ]),
        ],
      ),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      host: host,
    );
    await runtime.start();
    expect(runtime.commands, isNull, reason: 'nothing announced yet');

    await runtime.send('hi');
    await runtime.awaitTurn();
    await pump();
    const both = [
      SessionCommand(
        name: 'review',
        description: 'Review the changes',
        hint: 'what to focus on',
      ),
      SessionCommand(name: 'compact', description: 'Compact the context'),
    ];
    expect(host.commands.single.sessionId, 's1');
    expect(host.commands.single.commands, both);
    expect(runtime.commands!.commands, both);

    final modes = AcpSessionModes(
      runtimeOf: (_) => runtime,
      running: () => [runtime],
    );
    expect(
      modes.greeting().whereType<SessionCommandsChanged>().single.commands,
      both,
    );

    await runtime.send('again');
    await runtime.awaitTurn();
    await pump();
    expect(host.commands.last.commands, [both.last]);

    await runtime.stop();
    expect(host.commands.last.commands, isEmpty, reason: 'the agent is gone');
    expect(modes.greeting().whereType<SessionCommandsChanged>(), isEmpty);
  });

  test('commands announced while a session loads are not lost to the '
      'replay', () async {
    final process = FakeAcpProcess(
      FakeAcpAgent(loadReplay: const [AvailableCommandsUpdate([compact])]),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      host: host,
      resumeSessionId: 'earlier',
    );
    final outcome = await runtime.start();
    expect(outcome.resumed, isTrue);
    await pump();
    expect(runtime.commands!.commands.single.name, 'compact');
    await runtime.stop();
  });
}

class _CommandsHost extends RecordingHost {
  final commands = <SessionCommandsChanged>[];

  @override
  void commandsChanged(SessionCommandsChanged change) => commands.add(change);
}
