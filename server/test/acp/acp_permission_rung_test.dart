import 'dart:io';

import 'package:agent_cli/descriptors.dart' show AcpLaunchSpec, PermissionRisk;
import 'package:karmashala_acp/karmashala_acp.dart'
    show PermissionSelected, SessionMode, SessionModeState, ToolKind;
import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'acp_fixture.dart';

/// **A permission request is answered by the rung the person last chose**,
/// at launch or with the mode picker since, and a read is allowed unasked at
/// every rung while anything that changes or runs things still asks.
void main() {
  late AppDatabase database;
  late Directory temp;
  late RecordingHost host;

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    temp = Directory.systemTemp.createTempSync('acp_rung_test');
    host = RecordingHost();
  });

  tearDown(() {
    database.close();
    temp.deleteSync(recursive: true);
  });

  const modes = SessionModeState(
    currentModeId: 'ask',
    availableModes: [
      SessionMode(id: 'plan', name: 'Plan'),
      SessionMode(id: 'ask', name: 'Ask'),
      SessionMode(id: 'yolo', name: 'Yolo'),
      SessionMode(id: 'mystery', name: 'Mystery'),
    ],
  );
  const spec = AcpLaunchSpec(
    modeNames: {
      PermissionRisk.readOnly: ['plan'],
      PermissionRisk.ask: ['ask'],
      PermissionRisk.autoRun: ['yolo'],
    },
  );

  /// Starts at [risk], picks [picked] if given, then the agent asks for one
  /// call of [kind]; answers whether the runtime decided it unasked.
  Future<bool> answeredUnasked({
    required PermissionRisk risk,
    String? picked,
    ToolKind kind = ToolKind.edit,
  }) async {
    final process = FakeAcpProcess(
      FakeAcpAgent(
        modes: modes,
        turns: [
          FakeTurn([
            FakeStep.toolCall(
              toolCallId: 'c1',
              title: 'A call',
              kind: kind,
              permissionOptions: fakePermissionOptions,
            ),
          ]),
        ],
      ),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      host: host,
      spec: spec,
      risk: risk,
    );
    await runtime.start();
    if (picked != null) await runtime.setMode(picked);
    await runtime.send('Go');
    await pump();
    final unasked = !runtime.hasOpenPermission;
    if (!unasked) {
      await runtime.answerPermission(approve: true, toolCallId: 'c1');
    }
    await runtime.awaitTurn();
    expect(process.agent.permissionOutcomes, [
      const PermissionSelected('allow'),
    ]);
    await runtime.stop();
    return unasked;
  }

  test('launched at ask and raised to an automatic mode, a request is '
      'allowed unasked', () async {
    expect(
      await answeredUnasked(risk: PermissionRisk.ask, picked: 'yolo'),
      isTrue,
    );
  });

  test('launched automatic and lowered to ask, a request asks', () async {
    expect(
      await answeredUnasked(risk: PermissionRisk.autoRun, picked: 'ask'),
      isFalse,
    );
  });

  test('launched automatic and lowered to plan, a request asks', () async {
    expect(
      await answeredUnasked(risk: PermissionRisk.autoRun, picked: 'plan'),
      isFalse,
    );
  });

  test('a picked mode the spec cannot place allows nothing unasked', () async {
    expect(
      await answeredUnasked(risk: PermissionRisk.autoRun, picked: 'mystery'),
      isFalse,
    );
  });

  test('launched automatic and left there, a request is allowed', () async {
    expect(await answeredUnasked(risk: PermissionRisk.autoRun), isTrue);
  });

  for (final rung in [PermissionRisk.readOnly, PermissionRisk.ask]) {
    for (final kind in [ToolKind.read, ToolKind.search]) {
      test('at ${rung.name} a ${kind.raw} is allowed unasked', () async {
        expect(await answeredUnasked(risk: rung, kind: kind), isTrue);
      });
    }
    for (final kind in [
      ToolKind.execute,
      ToolKind.edit,
      ToolKind.delete,
      ToolKind.move,
      ToolKind.fetch,
    ]) {
      test('at ${rung.name} a ${kind.raw} still asks', () async {
        expect(await answeredUnasked(risk: rung, kind: kind), isFalse);
      });
    }
  }

  test(
    'a read is allowed unasked after the mode picker lowers to plan',
    () async {
      expect(
        await answeredUnasked(
          risk: PermissionRisk.autoRun,
          picked: 'plan',
          kind: ToolKind.read,
        ),
        isTrue,
      );
    },
  );
  test('modes placed by name are found when their ids are URLs', () async {
    const url = 'https://agentclientprotocol.com/protocol/session-modes';
    final process = FakeAcpProcess(
      FakeAcpAgent(
        modes: const SessionModeState(
          currentModeId: '$url#agent',
          availableModes: [
            SessionMode(id: '$url#agent', name: 'Agent'),
            SessionMode(id: '$url#plan', name: 'Plan'),
            SessionMode(id: '$url#autopilot', name: 'Autopilot'),
          ],
        ),
        turns: [
          const FakeTurn([
            FakeStep.toolCall(
              toolCallId: 'c1',
              title: 'Edit',
              kind: ToolKind.edit,
              permissionOptions: fakePermissionOptions,
            ),
          ]),
        ],
      ),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      host: host,
      spec: const AcpLaunchSpec(
        modeNames: {
          PermissionRisk.readOnly: ['Plan'],
          PermissionRisk.ask: ['Agent'],
          PermissionRisk.autoRun: ['Autopilot'],
        },
      ),
      risk: PermissionRisk.readOnly,
    );
    await runtime.start();
    expect(runtime.modes?.currentModeId, '$url#plan');
    await runtime.setMode('$url#autopilot');
    await runtime.send('Go');
    await runtime.awaitTurn();
    expect(runtime.hasOpenPermission, isFalse);
    expect(process.agent.permissionOutcomes, [
      const PermissionSelected('allow'),
    ]);
    await runtime.stop();
  });
}
