import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:karmashala/src/features/agents/presentation/permission_mode_picker.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/sessions/application/session_handoff_service.dart';
import 'package:karmashala_session/lineage.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/presentation/continue_with_dialog.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

/// One mode and no more — the agent a pick made elsewhere cannot survive onto.
///
/// Local rather than the shared `testPermissionSupport`, which has all three
/// rungs: an agent that expresses everything cannot show what the picker does
/// with a mode it does not have, which is what half of this file is about.
const _askOnly = AgentPermissionSupport.axes(
  evidence: 'test fixture — not a real CLI',
  axes: [
    AgentPermissionAxis(
      id: 'mode',
      label: 'Permission mode',
      description: 'How much Prompting CLI may do without asking.',
      defaultValueId: 'ask',
      values: [
        AgentPermissionValue(
          id: 'ask',
          label: 'Ask every time',
          shortLabel: 'Ask',
          description: 'Prompts before edits and commands.',
          arguments: ['--careful'],
          permits: PermissionRisk.ask,
          evidence: 'test fixture',
        ),
      ],
    ),
  ],
);

/// Two modes, which is what makes the picker's rules visible: one the source
/// session is already on, and one it is not.
const _askOrBypass = AgentPermissionSupport.axes(
  evidence: 'test fixture — not a real CLI',
  axes: [
    AgentPermissionAxis(
      id: 'mode',
      label: 'Permission mode',
      description: 'How much Flexible CLI may do without asking.',
      defaultValueId: 'ask',
      values: [
        AgentPermissionValue(
          id: 'ask',
          label: 'Ask every time',
          shortLabel: 'Ask',
          description: 'Prompts before edits and commands.',
          arguments: ['--careful'],
          permits: PermissionRisk.ask,
          evidence: 'test fixture',
        ),
        AgentPermissionValue(
          id: 'bypass',
          label: 'Bypass (full autonomy)',
          shortLabel: 'Bypass',
          description: 'No prompts and no sandbox.',
          arguments: ['--trust-me'],
          permits: PermissionRisk.bypass,
          isDangerous: true,
          evidence: 'test fixture',
        ),
      ],
    ),
  ],
);

const _prompting = AgentDescriptor(
  id: 'prompting',
  displayName: 'Prompting CLI',
  binaries: AgentBinaries(windows: ['p'], posix: ['p']),
  launch: AgentLaunchSpec(
    permission: _askOnly,
    prompt: AgentPromptSupport.positional(),
    fork: AgentForkSupport.native(
      resume: AgentResume.flag('--resume'),
      evidence: 'p --help',
    ),
  ),
);

/// Expresses two modes, which is what makes the picker's rules visible: one
/// the source session is already on, and one it is not.
const _flexible = AgentDescriptor(
  id: 'flexible',
  displayName: 'Flexible CLI',
  binaries: AgentBinaries(windows: ['f'], posix: ['f']),
  launch: AgentLaunchSpec(
    permission: _askOrBypass,
    prompt: AgentPromptSupport.positional(),
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
  bool followsDefault = false,
}) => HandoffTarget(
  installation: _install(id, descriptor.id),
  descriptor: descriptor,
  agentName: descriptor.displayName,
  permission: carryPermission(PermissionRisk.ask, descriptor),
  isSameAgent: isSameAgent,
  followsDefault: followsDefault,
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
  String? handedOffTo;
  PermissionSelection? handedOffUnder;
  bool forked = false;
  PermissionSelection? forkedUnder;
  HandoffSourceBrief? packetBrief;
  HandoffSourceBrief? handedOffBrief;
  int briefRequests = 0;
  HandoffSourceBrief briefAnswer = const HandoffSourceBrief.written(
    'Half the parser is done.',
  );

  @override
  Future<SessionLaunchResult> handoffTo({
    required String sessionId,
    required String targetInstallationId,
    required String instruction,
    List<String> unresolvedTasks = const [],
    bool intoNewWorktree = false,
    PermissionSelection? permissionMode,
    HandoffSourceBrief? sourceBrief,
  }) async {
    handedOffTo = targetInstallationId;
    handedOffUnder = permissionMode;
    handedOffBrief = sourceBrief;
    return SessionLaunchResult(session: session());
  }

  @override
  Future<HandoffSourceBrief> requestSourceBrief({
    required String sessionId,
    num? timeoutSeconds,
  }) async {
    briefRequests++;
    return briefAnswer;
  }

  @override
  Future<SessionLaunchResult> forkSession({
    required String sessionId,
    String instruction = '',
    List<String> unresolvedTasks = const [],
    bool intoNewWorktree = false,
    PermissionSelection? permissionMode,
  }) async {
    forked = true;
    forkedUnder = permissionMode;
    return SessionLaunchResult(session: session());
  }

  @override
  Future<String> previewPacket({
    required String sessionId,
    required String targetAgentName,
    required String instruction,
    List<String> unresolvedTasks = const [],
    bool isFork = false,
    HandoffSourceBrief? sourceBrief,
  }) async {
    packetFor = targetAgentName;
    packetInstruction = instruction;
    packetWasFork = isFork;
    packetBrief = sourceBrief;
    return HandoffPacket(
      sourceAgentName: 'Prompting CLI',
      targetAgentName: targetAgentName,
      sourceTitle: 'Work',
      sourceSessionId: 'cli-1',
      instruction: instruction,
      unresolvedTasks: unresolvedTasks,
      sourceBrief: sourceBrief,
      isFork: isFork,
    ).render();
  }
}

/// The row that offers the source agent's own brief. Named rather than taken
/// by position: the dialog has two checkboxes now and position is not what
/// either test means.
final _askRow = find.widgetWithText(
  CheckboxListTile,
  'Ask Prompting CLI to write the brief first',
);

void main() {
  // Null until the dialog reads the provider, which is itself the answer to
  // "was anything launched": a test may ask before that has happened.
  _RecordingService? service;

  Future<void> pump(
    WidgetTester tester, {
    required SessionContinuation continuation,
    // Seeded here rather than set on `service` afterwards: the provider is
    // read lazily, so `service` still holds the *previous* test's recorder
    // until the dialog first asks for one.
    HandoffSourceBrief? briefAnswer,
  }) async {
    // A desktop window, which is where this dialog lives. At the test
    // default's 600px it is taller than the screen and the segmented button
    // scrolls out from under the pointer.
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionContinuationProvider.overrideWith((ref, _) => continuation),
          sessionHandoffServiceProvider.overrideWith((ref) {
            final recorder = _RecordingService(ref);
            if (briefAnswer != null) recorder.briefAnswer = briefAnswer;
            return service = recorder;
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
          _target(_flexible, id: 'a3'),
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
    // Twice, from one resolution: beside the target it belongs to, and again
    // under the picker for the agent currently chosen.
    expect(
      find.textContaining('Prompting CLI is told to use it'),
      findsNWidgets(2),
    );
    expect(find.textContaining('Carried from this session.'), findsOneWidget);
  });

  testWidgets('says when the mode is the Settings default, not a choice', (
    tester,
  ) async {
    await pump(
      tester,
      continuation: continuation(
        targets: [
          _target(
            _prompting,
            id: 'a1',
            isSameAgent: true,
            followsDefault: true,
          ),
        ],
      ),
    );

    // The source session never chose a mode, so this one is the Settings
    // default and the new session will go on following it. Reading "carried
    // from this session" would present a default as a decision, and hide that
    // it moves when the setting does.
    expect(find.textContaining('Carried from this session.'), findsNothing);
    expect(
      find.textContaining('Following the Prompting CLI default in Settings'),
      findsOneWidget,
    );
  });

  testWidgets('offers the chosen agent\'s modes, and nothing it lacks', (
    tester,
  ) async {
    await pump(tester, continuation: continuation());

    await tester.tap(find.byType(PermissionModePicker));
    await tester.pumpAndSettle();
    // Prompting CLI has only `ask`. Every row *is* one of the agent's own
    // modes now, so a mode it lacks is absent rather than disabled — the
    // disabled row is reserved for one axis superseding another.
    expect(
      find.widgetWithText(
        DesktopMenuDetailItem<PermissionAxisChoice>,
        'Ask every time',
      ),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(
        DesktopMenuDetailItem<PermissionAxisChoice>,
        'Bypass (full autonomy)',
      ),
      findsNothing,
    );
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    // Choosing the other agent re-resolves what is on offer.
    await tester.tap(find.text('Flexible CLI'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PermissionModePicker));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DesktopMenuDetailItem<PermissionAxisChoice>>(
            find.widgetWithText(
              DesktopMenuDetailItem<PermissionAxisChoice>,
              'Bypass (full autonomy)',
            ),
          )
          .enabled,
      isTrue,
    );
  });

  testWidgets('a mode the next agent cannot be put into does not survive the '
      'change of agent', (tester) async {
    await pump(tester, continuation: continuation());
    await tester.tap(find.text('Flexible CLI'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PermissionModePicker));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bypass (full autonomy)'));
    await tester.pumpAndSettle();
    expect(find.text('Bypass'), findsOneWidget);

    // Prompting CLI has no bypass, and nothing more permissive may be
    // substituted, so the selection falls to the safest mode it does have —
    // and the row says what this agent will actually be told.
    await tester.tap(find.text('Prompting CLI'));
    await tester.pumpAndSettle();
    expect(find.text('Bypass'), findsNothing);
    expect(find.text('Ask'), findsOneWidget);
    expect(
      find.textContaining('Ask every time — Prompting CLI is told to use it'),
      findsWidgets,
    );
  });

  testWidgets('hands off under the mode picked for the chosen agent', (
    tester,
  ) async {
    await pump(tester, continuation: continuation());
    await tester.enterText(find.byType(TextField).first, 'Take it from here.');
    await tester.tap(find.text('Flexible CLI'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PermissionModePicker));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bypass (full autonomy)'));
    await tester.pumpAndSettle();

    // Still nothing launched: picking a mode is not confirming the handoff.
    expect(service?.handedOffTo, isNull);

    await tester.tap(find.text('Hand off'));
    await tester.pumpAndSettle();
    expect(service!.handedOffTo, 'a3');
    expect(
      service!.handedOffUnder,
      const PermissionSelection({'mode': 'bypass'}),
    );
  });

  testWidgets('a fork runs under the mode picked for the same agent', (
    tester,
  ) async {
    await pump(tester, continuation: continuation());
    await tester.tap(find.text('Fork this one'));
    await tester.enterText(find.byType(TextField).first, 'branch it');
    await tester.pumpAndSettle();

    // The agent is not in question here, only the mode it branches under.
    await tester.tap(find.byType(PermissionModePicker));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ask every time'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fork'));
    await tester.pumpAndSettle();
    expect(service!.forked, isTrue);
    expect(service!.forkedUnder, const PermissionSelection({'mode': 'ask'}));
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
      find.textContaining('This is exactly what the next agent is told'),
      findsOneWidget,
    );
    expect(service!.packetInstruction, 'Finish the parser.');
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
    // And which of the two forks it is: a new process, not this session
    // branching in place.
    expect(
      find.textContaining('not this session branching in place'),
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
      find.widgetWithText(CheckboxListTile, 'Start in a new worktree'),
    );
    expect(checkbox.value, isFalse);
    expect(
      find.textContaining('same directory and on the same branch'),
      findsOneWidget,
    );
  });

  testWidgets('offers the source agent its own brief, and does not take it', (
    tester,
  ) async {
    await pump(tester, continuation: continuation());
    // Named, because it is that agent's quota being spent.
    expect(
      find.text('Ask Prompting CLI to write the brief first'),
      findsOneWidget,
    );
    final ask = tester.widget<CheckboxListTile>(_askRow);
    expect(ask.value, isFalse, reason: 'declining is the default');

    // Declining asks the source for nothing at all.
    await tester.enterText(find.byType(TextField).first, 'Finish it.');
    await tester.tap(find.text('Hand off'));
    await tester.pumpAndSettle();
    expect(service!.briefRequests, 0);
    expect(service!.handedOffBrief, isNull);
  });

  testWidgets('asks once, and the same answer reaches preview and launch', (
    tester,
  ) async {
    await pump(tester, continuation: continuation());
    await tester.ensureVisible(_askRow);
    await tester.tap(_askRow);
    await tester.enterText(find.byType(TextField).first, 'Finish it.');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Preview packet'));
    await tester.pumpAndSettle();
    expect(service!.packetBrief?.text, 'Half the parser is done.');

    await tester.tap(find.text('Hand off'));
    await tester.pumpAndSettle();
    expect(service!.handedOffBrief?.text, 'Half the parser is done.');
    // One turn of the source agent's quota, not two.
    expect(service!.briefRequests, 1);
  });

  testWidgets('says so on the row when the source did not write one', (
    tester,
  ) async {
    await pump(
      tester,
      continuation: continuation(),
      briefAnswer: const HandoffSourceBrief.notWritten(
        'it had not answered when this stopped waiting.',
      ),
    );
    await tester.ensureVisible(_askRow);
    await tester.tap(_askRow);
    await tester.enterText(find.byType(TextField).first, 'Finish it.');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Preview packet'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('It did not: it had not answered'),
      findsOneWidget,
    );
  });
}
