import 'package:chitragupta/src/features/agents/domain/agent_descriptor.dart';
import 'package:chitragupta/src/features/agents/domain/agent_installation.dart';
import 'package:chitragupta/src/features/agents/domain/permission_carry.dart';
import 'package:chitragupta/src/features/environments/domain/environment_path.dart';
import 'package:chitragupta/src/features/sessions/application/session_handoff_service.dart';
import 'package:chitragupta/src/features/sessions/domain/handoff_packet.dart';
import 'package:chitragupta/src/features/sessions/domain/session_fork.dart';
import 'package:chitragupta/src/features/sessions/presentation/continue_with_dialog.dart';
import 'package:chitragupta/src/features/settings/domain/permission_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

const _prompting = AgentDescriptor(
  id: 'prompting',
  displayName: 'Prompting CLI',
  binaries: AgentBinaries(windows: ['p'], posix: ['p']),
  launch: AgentLaunchSpec(
    permissionModes: {
      PermissionMode.ask: PermissionModeMapping.exact(['--careful']),
    },
    acceptsPromptArgument: true,
    fork: AgentForkSupport.native(
      resume: AgentResume.flag('--resume'),
      evidence: 'p --help',
    ),
  ),
);

const _mute = AgentDescriptor(
  id: 'mute',
  displayName: 'Mute CLI',
  binaries: AgentBinaries(windows: ['m'], posix: ['m']),
);

AgentInstallation _install(String id, String agentId) => AgentInstallation(
  id: id,
  agentId: agentId,
  executable: EnvironmentPath(environmentId: 'windows', path: 'C:\\$agentId'),
  createdAt: testTime,
);

HandoffTarget _target(
  AgentDescriptor descriptor, {
  required String id,
  bool isSameAgent = false,
}) => HandoffTarget(
  installation: _install(id, descriptor.id),
  descriptor: descriptor,
  agentName: descriptor.displayName,
  permission: carryPermission(PermissionMode.ask, descriptor),
  isSameAgent: isSameAgent,
  refusal: descriptor.launch.acceptsPromptArgument
      ? null
      : '${descriptor.displayName} takes no opening prompt, so the handoff '
            'packet could not be delivered.',
);

/// Records what the dialog asked for, instead of launching anything.
class _RecordingService extends SessionHandoffService {
  _RecordingService(super.ref);

  String? packetFor;
  String? packetInstruction;
  bool packetWasFork = false;

  @override
  Future<HandoffPacket> buildPacket({
    required String sessionId,
    required String targetAgentName,
    required String instruction,
    List<String> unresolvedTasks = const [],
    bool isFork = false,
    HandoffRecapBudget budget = const HandoffRecapBudget(),
  }) async {
    packetFor = targetAgentName;
    packetInstruction = instruction;
    packetWasFork = isFork;
    return HandoffPacket(
      sourceAgentName: 'Prompting CLI',
      targetAgentName: targetAgentName,
      sourceTitle: 'Work',
      sourceSessionId: 'cli-1',
      instruction: instruction,
      unresolvedTasks: unresolvedTasks,
      isFork: isFork,
    );
  }
}

void main() {
  late _RecordingService service;

  Future<void> pump(
    WidgetTester tester, {
    required SessionContinuation continuation,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionContinuationProvider.overrideWith((ref, _) => continuation),
          sessionHandoffServiceProvider.overrideWith((ref) {
            service = _RecordingService(ref);
            return service;
          }),
        ],
        child: const MaterialApp(
          home: Scaffold(body: ContinueWithDialog(sessionId: 's1')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  SessionContinuation continuation({
    List<HandoffTarget>? targets,
    AgentDescriptor? forkAgent = _prompting,
    String? externalSessionId = 'cli-1',
  }) => SessionContinuation(
    targets:
        targets ??
        [
          _target(_prompting, id: 'a1', isSameAgent: true),
          _target(_mute, id: 'a2'),
        ],
    plan: SessionForkPlan.decide(
      descriptor: forkAgent,
      agentName: forkAgent?.displayName ?? 'this agent',
      externalSessionId: externalSessionId,
    ),
  );

  testWidgets('lists every target, disabling the one that cannot be told', (
    tester,
  ) async {
    await pump(tester, continuation: continuation());

    expect(find.text('Prompting CLI'), findsOneWidget);
    expect(find.text('Mute CLI'), findsOneWidget);
    // Listed and disabled with the reason, never hidden — the same rule the
    // permission chip follows.
    expect(find.textContaining('takes no opening prompt'), findsOneWidget);
    expect(find.text('same agent, fresh conversation'), findsOneWidget);
  });

  testWidgets('shows what the permission mode becomes before launch', (
    tester,
  ) async {
    await pump(tester, continuation: continuation());
    expect(
      find.textContaining('Prompting CLI is told to use it'),
      findsOneWidget,
    );
  });

  testWidgets('will not start until the user has written an instruction', (
    tester,
  ) async {
    await pump(tester, continuation: continuation());

    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);

    await tester.enterText(find.byType(TextField).first, 'Take it from here.');
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
  });

  testWidgets('previews exactly what the next agent will receive', (
    tester,
  ) async {
    await pump(tester, continuation: continuation());
    await tester.enterText(find.byType(TextField).first, 'Finish the parser.');
    await tester.tap(find.text('Preview packet'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('This is exactly what the next agent receives'),
      findsOneWidget,
    );
    expect(service.packetInstruction, 'Finish the parser.');
    // Nothing was launched by previewing.
    expect(find.text('Hand off'), findsOneWidget);
  });

  testWidgets('the fork tab states what the CLI will really do', (
    tester,
  ) async {
    await pump(tester, continuation: continuation());
    await tester.tap(find.text('Fork this one'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Prompting CLI forks this itself'),
      findsOneWidget,
    );
    expect(find.text('Fork'), findsOneWidget);
  });

  testWidgets('a fork that will really be a handoff says so first', (
    tester,
  ) async {
    // The live degradation: the agent can fork, but we never learned the CLI's
    // id for this conversation.
    await pump(tester, continuation: continuation(externalSessionId: null));
    await tester.tap(find.text('Fork this one'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('hand off a written recap instead'),
      findsOneWidget,
    );
  });

  testWidgets('a fork the agent cannot do at all is refused, not offered', (
    tester,
  ) async {
    await pump(tester, continuation: continuation(forkAgent: _mute));
    await tester.tap(find.text('Fork this one'));
    await tester.enterText(find.byType(TextField).first, 'branch it');
    await tester.pumpAndSettle();

    expect(find.textContaining('no verified way to fork'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
  });

  testWidgets('defaults to continuing in the same worktree', (tester) async {
    await pump(tester, continuation: continuation());
    final checkbox = tester.widget<CheckboxListTile>(
      find.byType(CheckboxListTile),
    );
    expect(checkbox.value, isFalse);
    expect(
      find.textContaining('same directory and on the same branch'),
      findsOneWidget,
    );
  });
}
