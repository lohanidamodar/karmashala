import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_handoff_service.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/lineage.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala/src/features/sessions/presentation/delivery_strip.dart';
import 'package:karmashala/src/features/verification/domain/session_verdict.dart';
import 'package:karmashala_verification/verification.dart';
import 'package:karmashala/src/features/verification/presentation/review_invitation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_data_server.dart';
import '../../support/test_machine.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';
import '../terminal/fake_instance.dart';

/// The review offer on the delivery strip — the button the verdict was drawn
/// to sit beside.
///
/// Three rules are asserted here, and they are the whole feature:
///
/// **What the verdict wants.** Six of the seven states want a review; the words
/// change with the record, not with the finding. The seventh — a run open on a
/// live session — wants nothing, because the check the button would start is
/// the one already running.
///
/// **Hidden, not disabled, when nobody can be asked.** The strip is drawn on
/// every session, so a dead control here would be a permanent broken-looking
/// feature on a machine with one agent installed — the argument the follow-up
/// row already settled. The refusal still has a home: `ReviewAction`'s own
/// disabled button, where the control is the surface's subject.
///
/// **Nothing runs without a press.** Drawing the strip starts no agent, and the
/// press goes through `ReviewSessionService` rather than a second path the
/// strip invented — which is what keeps the permission cap on it.
void main() {
  late TestMachine db;
  late FakeDataServer server;
  late DataClient data;

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    data = await server.connect();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows
      // `a1` did the work; `a2` is the only agent that could check it.
      ..insert(agentInstallation())
      ..insert(
        agentInstallation(
          id: 'a2',
          agentId: AgentIds.codex,
          path: r'C:\Users\me\.bin\codex.exe',
        ),
      );
  });

  /// Nowhere to continue to: this file is about the review, not the handoff.
  final noContinuation = SessionContinuation(
    targets: const [],
    plan: SessionForkPlan.decide(descriptor: null, agentName: 'Test CLI'),
  );

  const delivery = SessionDelivery(
    branch: 'work',
    baseBranch: 'origin/main',
    hasRemote: true,
    dirtyFiles: 1,
  );

  void insertSession({SessionStatus status = SessionStatus.idle}) =>
      db.server.sessionRows.insert(session(id: 's1', status: status));

  /// A run against session `s1`, open unless [verdict] is given.
  void insertRun({
    required String id,
    VerificationVerdict? verdict,
    DateTime? startedAt,
  }) {
    final dao = db.server.verificationRows;
    dao.insertRun(
      VerificationRun(
        id: id,
        title: 'the login page accepts a good password',
        target: const VerificationTarget.change(),
        startedAt: startedAt ?? testTime,
        artifactDirectory: 'C:/art/$id',
        sessionId: 's1',
        // Another session's verdict: a self-graded pass reads differently,
        // and this file is about the offer, not the attribution.
        producedBySessionId: 's2',
      ),
    );
    if (verdict != null) {
      dao.finishRun(
        id,
        finishedAt: (startedAt ?? testTime).add(const Duration(minutes: 3)),
        verdict: verdict,
      );
    }
  }

  Widget strip({bool hostedOnTerminal = false}) => ProviderScope(
    overrides: [
      dataClientProvider.overrideWithValue(data),
      ...fakeTerminalOverrides(machine: db),
      clockProvider.overrideWithValue(FixedClock(testTime)),
      idGeneratorProvider.overrideWithValue(SequentialIdGenerator('revsid')),
      // Nothing here may shell out: a press launches a real session over fake
      // terminals, and that is the point of the press test.
      commandRunnerFactoryProvider.overrideWithValue(
        FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
      ),
      hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
      sessionDeliveryProvider.overrideWith((ref, _) async => delivery),
      sessionContinuationProvider.overrideWith((ref, _) => noContinuation),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: DeliveryStrip(
          sessionId: 's1',
          hostedOnTerminal: hostedOnTerminal,
        ),
      ),
    ),
  );

  Future<void> pump(
    WidgetTester tester, {
    bool hostedOnTerminal = false,
  }) async {
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(strip(hostedOnTerminal: hostedOnTerminal));
    await tester.pumpAndSettle();
  }

  testWidgets('a session nothing ever checked is offered no first check on '
      'the bar', (tester) async {
    insertSession();
    await pump(tester);

    // Verification nobody runs was a "Not checked" and a button on every
    // session (owner, 2026-10-07): the bar says nothing until a check has run.
    expect(find.text('Not checked'), findsNothing);
    expect(find.text('Check this'), findsNothing);
  });

  testWidgets('a check already running is offered nothing', (tester) async {
    insertSession(status: SessionStatus.running);
    insertRun(id: 'v1');
    await pump(tester);

    // The one state with no offer: a second agent asked the same question
    // would cost tokens to race the answer already being written, and whichever
    // finished last would supersede the other.
    expect(find.text('Checking…'), findsOneWidget);
    expect(find.text('Check this'), findsNothing);
    expect(find.text('Check again'), findsNothing);
  });

  testWidgets('a run nobody finished still wants one that does', (
    tester,
  ) async {
    insertSession(status: SessionStatus.completed);
    insertRun(id: 'v1');
    await pump(tester);

    expect(find.text('Check unfinished'), findsOneWidget);
    expect(find.text('Check again'), findsOneWidget);
    expect(find.text('Check this'), findsNothing);
  });

  testWidgets('a verdict word this build cannot read still wants a check it '
      'can read', (tester) async {
    insertSession();
    insertRun(id: 'v1');
    // A verdict word this build cannot read arrives as none on a finished run.
    db.server.verificationRows.finishRun(
      'v1',
      finishedAt: DateTime.utc(2026, 1, 2, 3, 10),
    );
    await pump(tester);

    expect(find.text('Verdict not recorded'), findsOneWidget);
    expect(find.text('Check again'), findsOneWidget);
  });

  // A test each: the three verdicts must all be offered a re-check, and none of
  // them may be offered it in the words a never-checked session gets.
  for (final (verdict, label) in const [
    (VerificationVerdict.pass, 'Checked: pass'),
    (VerificationVerdict.fail, 'Checked: fail'),
    (VerificationVerdict.inconclusive, 'Checked: inconclusive'),
  ]) {
    testWidgets('"$label" is offered another check, not a first one', (
      tester,
    ) async {
      insertSession();
      insertRun(id: 'v1', verdict: verdict);
      await pump(tester);

      expect(find.text(label), findsOneWidget);
      // "Check this" under "Checked: pass" would be the strip arguing with
      // itself in two words.
      expect(find.text('Check this'), findsNothing);
      expect(find.text('Check again'), findsOneWidget);
    });
  }

  testWidgets('nobody to ask draws nothing at all, not a dead button', (
    tester,
  ) async {
    // One agent installed, and a session cannot check its own work.
    server.installationRows.delete('a2');
    insertSession();
    await pump(tester);

    // Nothing checked draws nothing on the bar, and there is no button.
    expect(find.text('Not checked'), findsNothing);
    expect(find.text('Check this'), findsNothing);
    expect(find.text('Check again'), findsNothing);
    expect(find.byIcon(AppIcons.listMagnifyingGlass), findsNothing);
  });

  testWidgets('drawing the strip starts no agent', (tester) async {
    insertSession();
    await pump(tester);

    // The standing rule, asserted where it is easiest to break: the offer is
    // computed on every rebuild and starts nothing by existing.
    expect(db.server.sessionRows.getAll(), hasLength(1));
  });

  testWidgets('the press is the say-so, and it goes through the one review '
      'path', (tester) async {
    insertSession();
    insertRun(id: 'v1', verdict: VerificationVerdict.pass);
    await pump(tester);

    await tester.tap(find.text('Check again'));
    await tester.pumpAndSettle();

    // Launched by `ReviewSessionService`, not by anything the strip invented:
    // the row it writes is the one that carries the capped permission.
    final review = db.server.sessionRows.getAll().firstWhere(
      (s) => s.id != 's1',
    );
    expect(review.parentSessionId, 's1');
    expect(review.parentLink, SessionLink.spawn);
    expect(review.agentInstallationId, 'a2');
    expect(review.title, 'Review · Work');
  });

  testWidgets('what pressing it will do is on the tooltip before it is '
      'pressed', (tester) async {
    insertSession();
    insertRun(id: 'v1', verdict: VerificationVerdict.pass);
    await pump(tester);

    final tooltip = tester.widget<Tooltip>(
      find.ancestor(
        of: find.text('Check again'),
        matching: find.byType(Tooltip),
      ),
    );
    // The permission cap is the reason there is no confirmation dialog, so the
    // sentence that states it has to be readable before the press.
    expect(tooltip.message, contains('Codex CLI'));
    expect(tooltip.message, contains('read and run, never write'));
  });

  testWidgets('the session bar under the terminal offers it too', (
    tester,
  ) async {
    insertSession();
    insertRun(id: 'v1', verdict: VerificationVerdict.pass);
    await pump(tester, hostedOnTerminal: true);

    // The bar draws the verdict itself, through `DeliveryStateLine`; the
    // control belongs in the row of controls below it.
    expect(find.text('Check again'), findsOneWidget);
  });

  testWidgets('it survives the window matrix with the verdict beside it', (
    tester,
  ) async {
    insertSession();
    insertRun(id: 'v1', verdict: VerificationVerdict.pass);
    await pump(tester);
    // Both present, so the matrix below is measuring the crowded strip rather
    // than one that quietly dropped its newest control.
    expect(find.text('Checked: pass'), findsOneWidget);
    expect(find.text('Check again'), findsOneWidget);

    await expectSurvivesWindowMatrix(
      tester,
      build: strip,
      because: 'the strip now carries a stage, a verdict and a button',
    );
  });

  testWidgets('the terminal host survives it too', (tester) async {
    insertSession();
    insertRun(id: 'v1', verdict: VerificationVerdict.fail);
    await expectSurvivesWindowMatrix(
      tester,
      build: () => strip(hostedOnTerminal: true),
      because: 'the bar is the narrower of the two hosts',
    );
  });

  group('the rule itself', () {
    test('nothing checked wants a first check', () {
      expect(
        ReviewInvitation.forVerdict(SessionVerdictState.notRecorded),
        ReviewInvitation.check,
      );
    });

    test('a check in flight wants none', () {
      expect(
        ReviewInvitation.forVerdict(SessionVerdictState.inProgress),
        isNull,
      );
    });

    test('every state that has a run behind it wants another', () {
      for (final state in const [
        SessionVerdictState.unfinished,
        SessionVerdictState.verdictNotRecorded,
        SessionVerdictState.pass,
        SessionVerdictState.fail,
        SessionVerdictState.inconclusive,
      ]) {
        expect(
          ReviewInvitation.forVerdict(state),
          ReviewInvitation.checkAgain,
          reason: '$state',
        );
      }
    });

    test('all seven states are classified', () {
      // The switch behind [ReviewInvitation.forVerdict] is exhaustive, so an
      // eighth state would not compile until somebody decided what it wants.
      // This is the reminder that the decision is a product one.
      expect(SessionVerdictState.values, hasLength(7));
    });
  });
}
