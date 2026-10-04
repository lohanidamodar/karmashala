import 'dart:io';

import 'package:agent_cli/descriptors.dart'
    show AcpLaunchSpec, PermissionRisk, claudeAcpDescriptor;
import 'package:karmashala_acp/karmashala_acp.dart'
    show
        PermissionOption,
        PermissionOptionKind,
        PermissionSelected,
        SessionMode,
        SessionModeState,
        ToolKind;
import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_host/src/acp/acp_session_runtime.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'acp_fixture.dart';

/// **Approving a plan over ACP never raises the session's permissions**: the
/// allow option chosen is the one whose mode is at or below the session's
/// rung, read by option id against the agent's declared modes — for the
/// stream-json bridge, whose ids are mode ids, and for the claude-agent-acp
/// adapter, whose ids its spec maps — never by the option's words.
void main() {
  late AppDatabase database;
  late Directory temp;
  late RecordingHost host;

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    temp = Directory.systemTemp.createTempSync('acp_plan_test');
    host = RecordingHost();
  });

  tearDown(() {
    database.close();
    temp.deleteSync(recursive: true);
  });

  final spec = claudeAcpDescriptor.acp!;

  /// feat/claude-native's bridge, `_canUseTool` for ExitPlanMode.
  const bridge = [
    PermissionOption(
      optionId: 'acceptEdits',
      name: 'Yes, and accept edits',
      kind: PermissionOptionKind.allowAlways,
    ),
    PermissionOption(
      optionId: 'default',
      name: 'Yes, and ask before edits',
      kind: PermissionOptionKind.allowOnce,
    ),
    PermissionOption(
      optionId: 'plan',
      name: 'No, keep planning',
      kind: PermissionOptionKind.rejectOnce,
    ),
  ];

  /// claude-agent-acp 0.85.1, buildExitPlanModePermissionOptions with auto
  /// and bypass available and a plan in the input.
  const adapter = [
    PermissionOption(
      optionId: 'exit-plan-clear-auto',
      name: 'Yes, clear context and use auto mode',
      kind: PermissionOptionKind.allowAlways,
    ),
    PermissionOption(
      optionId: 'exit-plan-auto',
      name: 'Yes, and use auto mode',
      kind: PermissionOptionKind.allowAlways,
    ),
    PermissionOption(
      optionId: 'exit-plan-bypass',
      name: 'Yes, and bypass permissions',
      kind: PermissionOptionKind.allowAlways,
    ),
    PermissionOption(
      optionId: 'exit-plan-default',
      name: 'Yes, manually approve edits',
      kind: PermissionOptionKind.allowOnce,
    ),
    PermissionOption(
      optionId: 'reject',
      name: 'No, keep planning',
      kind: PermissionOptionKind.rejectOnce,
    ),
  ];

  Future<(AcpSessionRuntime, FakeAcpProcess)> asking(
    List<PermissionOption> options, {
    required PermissionRisk risk,
    AcpLaunchSpec? launch,
    String? pickedMode,
  }) async {
    final process = FakeAcpProcess(
      FakeAcpAgent(
        modes: claudeModes,
        turns: [
          FakeTurn([
            // The agent enters plan mode itself before it asks.
            if (pickedMode != null) const FakeStep.mode('plan'),
            FakeStep.toolCall(
              toolCallId: 'plan-1',
              title: 'Ready to code?',
              kind: ToolKind.switchMode,
              rawInput: const {'plan': '1. Fix the parser'},
              permissionOptions: options,
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
      spec: launch ?? spec,
      risk: risk,
    );
    await runtime.start();
    // The mode picker, after launch.
    if (pickedMode != null) await runtime.setMode(pickedMode);
    await runtime.send('Plan it');
    await pump();
    return (runtime, process);
  }

  test('the ask names the call by its kind, with the plan', () async {
    final (runtime, _) = await asking(bridge, risk: PermissionRisk.ask);
    final ask = host.statuses.last.toolAsk!;
    expect(ask.kind, 'switch_mode');
    expect(ask.input['plan'], '1. Fix the parser');
    await runtime.stop();
  });

  for (final (rung, chosen) in [
    (PermissionRisk.ask, 'default'),
    (PermissionRisk.acceptEdits, 'acceptEdits'),
    // Approving a plan leaves read-only; asking before every edit is the
    // least it can be.
    (PermissionRisk.readOnly, 'default'),
  ]) {
    test('the bridge, at ${rung.name}: $chosen', () async {
      final (runtime, process) = await asking(bridge, risk: rung);
      if (runtime.hasOpenPermission) {
        await runtime.answerPermission(approve: true, toolCallId: 'plan-1');
      }
      await runtime.awaitTurn();
      expect(process.agent.permissionOutcomes, [PermissionSelected(chosen)]);
      await runtime.stop();
    });
  }

  for (final (rung, chosen) in [
    (PermissionRisk.ask, 'exit-plan-default'),
    // Auto mode's rung is not one this spec names, so it is never chosen.
    (PermissionRisk.acceptEdits, 'exit-plan-default'),
    (PermissionRisk.bypass, 'exit-plan-bypass'),
  ]) {
    test('the adapter, at ${rung.name}: $chosen', () async {
      final (runtime, process) = await asking(adapter, risk: rung);
      if (runtime.hasOpenPermission) {
        await runtime.answerPermission(approve: true, toolCallId: 'plan-1');
      }
      await runtime.awaitTurn();
      expect(process.agent.permissionOutcomes, [PermissionSelected(chosen)]);
      await runtime.stop();
    });
  }

  for (final (name, options, reject) in [
    ('bridge', bridge, 'plan'),
    ('adapter', adapter, 'reject'),
  ]) {
    test('keep planning is the offered reject: the $name', () async {
      final (runtime, process) = await asking(
        options,
        risk: PermissionRisk.acceptEdits,
      );
      await runtime.answerPermission(approve: false, toolCallId: 'plan-1');
      await runtime.awaitTurn();
      expect(process.agent.permissionOutcomes, [PermissionSelected(reject)]);
      await runtime.stop();
    });
  }

  for (final (launched, picked, chosen) in [
    (PermissionRisk.ask, 'acceptEdits', 'acceptEdits'),
    (PermissionRisk.acceptEdits, 'default', 'default'),
  ]) {
    test('the mode picked after launch is the ceiling: launched at '
        '${launched.name}, picked $picked, approves $chosen', () async {
      final (runtime, process) = await asking(
        bridge,
        risk: launched,
        pickedMode: picked,
      );
      await runtime.answerPermission(approve: true, toolCallId: 'plan-1');
      await runtime.awaitTurn();
      expect(process.agent.permissionOutcomes, [PermissionSelected(chosen)]);
      await runtime.stop();
    });
  }
}

/// The modes claude-agent-acp and the stream-json bridge offer.
const claudeModes = SessionModeState(
  currentModeId: 'default',
  availableModes: [
    SessionMode(id: 'plan', name: 'Plan'),
    SessionMode(id: 'default', name: 'Ask'),
    SessionMode(id: 'acceptEdits', name: 'Accept edits'),
    SessionMode(id: 'bypassPermissions', name: 'Bypass'),
  ],
);
