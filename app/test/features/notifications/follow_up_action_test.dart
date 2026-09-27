import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/policy.dart';
import 'package:karmashala/src/features/notifications/presentation/attention_inbox_view.dart';
import 'package:karmashala/src/features/sessions/application/session_handoff_service.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala_session/lineage.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala/src/features/sessions/presentation/continue_with_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` is not part of the main barrel in Riverpod 3.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/permission_fixtures.dart';
import '../../support/window_matrix.dart';
import '../../support/fake_data_server.dart';

/// Acting on a follow-up from the attention inbox.
///
/// The whole design is in what the row **does not** do. This repository's
/// standing rule is that nothing starts an agent without the user's say-so, so
/// the obvious reading of "act on it" — a row that relaunches the session on
/// one click — is the one thing forbidden here. What the row offers is a
/// shorter path to `ContinueWithDialog`, which is where the decision is made
/// and where the packet is shown before anything is launched. Every test below
/// is a way of pinning that: the offer opens a confirmation, the confirmation
/// is the only thing that starts anything, and dismissing it starts nothing.
const _prompting = AgentDescriptor(
  id: 'prompting',
  displayName: 'Prompting CLI',
  binaries: AgentBinaries(windows: ['p'], posix: ['p']),
  launch: AgentLaunchSpec(
    permission: testPermissionSupport,
    prompt: AgentPromptSupport.positional(),
    fork: AgentForkSupport.native(
      resume: AgentResume.flag('--resume'),
      evidence: 'p --help',
    ),
  ),
);

HandoffTarget _target(AgentDescriptor descriptor, {required String id}) =>
    HandoffTarget(
      installation: AgentInstallation(
        id: id,
        agentId: descriptor.id,
        executable: EnvironmentPath(
          environmentId: 'windows',
          path: 'C:\\${descriptor.id}',
        ),
        createdAt: testTime,
      ),
      descriptor: descriptor,
      agentName: descriptor.displayName,
      permission: carryPermission(PermissionRisk.ask, descriptor),
      isSameAgent: false,
    );

/// Records what the dialog asked for. Nothing here launches anything, so an
/// empty recorder is the proof that nothing was started.
class _RecordingService extends SessionHandoffService {
  _RecordingService(super.ref);

  final handoffs = <({String sessionId, String targetInstallationId})>[];
  final forks = <String>[];

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
    handoffs.add((
      sessionId: sessionId,
      targetInstallationId: targetInstallationId,
    ));
    return SessionLaunchResult(session: session());
  }

  @override
  Future<SessionLaunchResult> forkSession({
    required String sessionId,
    String instruction = '',
    List<String> unresolvedTasks = const [],
    bool intoNewWorktree = false,
    PermissionSelection? permissionMode,
  }) async {
    forks.add(sessionId);
    return SessionLaunchResult(session: session());
  }

  @override
  Future<HandoffPacket> buildPacket({
    required String sessionId,
    required String targetAgentName,
    required String instruction,
    List<String> unresolvedTasks = const [],
    bool isFork = false,
    HandoffSourceBrief? sourceBrief,
    HandoffRecapBudget budget = const HandoffRecapBudget(),
    HandoffDecisionBudget decisionBudget = const HandoffDecisionBudget(),
  }) async => HandoffPacket(
    sourceAgentName: 'Prompting CLI',
    targetAgentName: targetAgentName,
    sourceTitle: 'Fix login',
    sourceSessionId: 'cli-1',
    instruction: instruction,
    unresolvedTasks: unresolvedTasks,
    isFork: isFork,
  );
}

void main() {
  late ProviderContainer container;
  late Override workspace;
  late FakeDataServer server;
  _RecordingService? service;

  setUp(() async {
    service = null;
    server = FakeDataServer()
      ..environmentRows.upsert(windowsEnv())
      ..projectRows.insert(project())
      ..repositoryRows.insert(repository());
    workspace = await server.override();
    server.installationRows.insert(agentInstallation());
  });

  final somewhereToGo = SessionContinuation(
    targets: [_target(_prompting, id: 'a1')],
    plan: SessionForkPlan.decide(
      descriptor: _prompting,
      agentName: 'Prompting CLI',
      externalSessionId: 'cli-1',
    ),
  );

  /// Nothing installed and no fork: `SessionContinuation.isPossible` is false.
  final nowhereToGo = SessionContinuation(
    targets: const [],
    plan: SessionForkPlan.decide(descriptor: null, agentName: 'Prompting CLI'),
  );

  Widget inbox(SessionContinuation continuation) {
    container = ProviderContainer(
      overrides: [
        workspace,
        clockProvider.overrideWithValue(
          FixedClock(testTime.add(const Duration(hours: 2))),
        ),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => const Stream<AgentStatusReport>.empty(),
        ),
        sessionContinuationProvider.overrideWith((ref, _) => continuation),
        sessionHandoffServiceProvider.overrideWith(
          (ref) => service = _RecordingService(ref),
        ),
      ],
    );
    addTearDown(container.dispose);
    return UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: SizedBox(width: 380, child: AttentionInboxView())),
      ),
    );
  }

  Future<void> pump(
    WidgetTester tester, {
    SessionContinuation? continuation,
  }) async {
    // The dialog this row opens is a desktop dialog; at the 800x600 test
    // default its fields scroll out from under the pointer.
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(inbox(continuation ?? somewhereToGo));
    await tester.pump();
  }

  void insertCrashedSession() => server.sessionRows.insert(
    session(id: 's1', title: 'Fix login', status: SessionStatus.failed),
  );

  /// The offer, found by its glyph rather than its words, so the wording can
  /// change without the test pretending the control has gone.
  final offer = find.widgetWithIcon(IconButton, AppIcons.arrowBendDownRight);

  testWidgets('the row offers somewhere to take the follow-up', (tester) async {
    insertCrashedSession();
    await pump(tester);

    expect(offer, findsOneWidget);
    // Narrator reads the semantics tree, and the promise is the part of this
    // control worth hearing before pressing it.
    expect(
      tester.widget<IconButton>(offer).tooltip,
      contains(kContinueWithPromise),
    );
  });

  testWidgets('taking it opens the confirmation and starts nothing on its '
      'own', (tester) async {
    insertCrashedSession();
    await pump(tester);

    await tester.tap(offer);
    await tester.pumpAndSettle();

    // The standing rule, asserted: the row is a shorter path *to* a
    // confirmation, never a way past one.
    expect(find.byType(ContinueWithDialog), findsOneWidget);
    expect(find.text('Continue with…'), findsOneWidget);
    expect(service?.handoffs ?? const [], isEmpty);
    expect(service?.forks ?? const [], isEmpty);
    // And the session it came from is untouched — not restarted, not relisted.
    expect(server.sessionRows.getById('s1')!.status, SessionStatus.failed);
  });

  testWidgets('confirming does what "Continue with…" does today', (
    tester,
  ) async {
    insertCrashedSession();
    await pump(tester);

    await tester.tap(offer);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).first,
      'Pick the login fix back up.',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hand off'));
    await tester.pumpAndSettle();

    expect(service!.handoffs, [(sessionId: 's1', targetInstallationId: 'a1')]);
    expect(find.byType(ContinueWithDialog), findsNothing);
  });

  testWidgets('dismissing the confirmation starts nothing', (tester) async {
    insertCrashedSession();
    await pump(tester);

    await tester.tap(offer);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).first,
      'Pick the login fix back up.',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Null, not empty: the dialog reads the handoff service only when it is
    // asked to build a packet or to launch, so a cancelled offer never reaches
    // the thing that could start an agent at all.
    expect(service, isNull);
    expect(find.byType(ContinueWithDialog), findsNothing);
    // The follow-up is still listed: declining an offer is not dealing with
    // what the session left.
    expect(find.text('Fix login'), findsOneWidget);
  });

  testWidgets('with nowhere to continue to, the row does not pretend', (
    tester,
  ) async {
    insertCrashedSession();
    await pump(tester, continuation: nowhereToGo);

    expect(offer, findsNothing);
    // The way in is still there; only the offer that could not be honoured is
    // gone.
    expect(find.byTooltip('Dismiss'), findsOneWidget);
  });

  testWidgets('a finished turn is not offered a continuation', (tester) async {
    // Deliberately narrow: a follow-up is a session that *ended* and left
    // something behind, which is the case "Continue with…" answers. A turn
    // that finished belongs to a session that is still there to talk to.
    server.sessionRows.insert(
      session(id: 's1', title: 'Ship the parser', status: SessionStatus.idle),
    );
    await pump(tester);
    FakeDataServer.of(container.read(dataClientProvider)).attention.apply(
          InboxUpdate(
            news: [
              (
                session: const WatchedSession(
                  key: AgentSessionKey('prompting', 'cli-1'),
                  label: 'Ship the parser',
                  openId: 's1',
                  imported: false,
                ),
                reason: NotificationReason.finished,
              ),
            ],
          ),
        );
    await tester.pump();

    expect(find.text('Ship the parser'), findsOneWidget);
    expect(offer, findsNothing);
  });

  testWidgets('the row survives the window matrix', (tester) async {
    insertCrashedSession();
    final tree = inbox(somewhereToGo);
    await expectSurvivesWindowMatrix(
      tester,
      build: () => tree,
      because: 'the row now carries two icon buttons beside two lines of text',
    );
  });
}
