import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_handoff_service.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session_delivery.dart';
import 'package:karmashala/src/features/sessions/domain/session_fork.dart';
import 'package:karmashala/src/features/sessions/domain/session_status.dart';
import 'package:karmashala/src/features/sessions/presentation/delivery_strip.dart';
import 'package:karmashala/src/features/verification/data/verification_dao.dart';
import 'package:karmashala/src/features/verification/domain/session_verdict.dart';
import 'package:karmashala/src/features/verification/domain/verification_run.dart';
import 'package:karmashala/src/features/verification/domain/verification_target.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';
import '../terminal/fake_instance.dart';

/// The verification verdict on the delivery strip — G3's last surface.
///
/// Everything here is one assertion said six ways: **the strip must never imply
/// a verdict it does not have.** A pass and an absence are different facts, an
/// abandoned run and a running one are different facts, and a verdict word this
/// build cannot read is a seventh thing that is none of the six. Each one gets
/// its own words, and the test that matters most is the one for no run at all.
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
  });
  tearDown(() => db.close());

  /// Nowhere to continue to: this file is about the verdict, not the actions.
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
      SessionDao(db).insert(session(id: 's1', status: status));

  /// A run against session `s1`, open unless [verdict] is given.
  void insertRun({
    required String id,
    String title = 'the login page accepts a good password',
    DateTime? startedAt,
    VerificationVerdict? verdict,
    String? reason,
    String? producedBySessionId = 's1',
  }) {
    final dao = VerificationDao(db);
    dao.insertRun(
      VerificationRun(
        id: id,
        title: title,
        target: const VerificationTarget.browser('https://example.com'),
        startedAt: startedAt ?? testTime,
        artifactDirectory: 'C:/art/$id',
        sessionId: 's1',
        producedBySessionId: producedBySessionId,
      ),
    );
    if (verdict != null) {
      dao.finishRun(
        id,
        finishedAt: (startedAt ?? testTime).add(const Duration(minutes: 3)),
        verdict: verdict,
        reason: reason,
      );
    }
  }

  Widget strip() => ProviderScope(
    overrides: [
      ...fakeTerminalOverrides(database: db),
      clockProvider.overrideWithValue(FixedClock(testTime)),
      sessionDeliveryProvider.overrideWith((ref, _) async => delivery),
      sessionContinuationProvider.overrideWith((ref, _) => noContinuation),
    ],
    child: const MaterialApp(
      home: Scaffold(body: DeliveryStrip(sessionId: 's1')),
    ),
  );

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(strip());
    await tester.pumpAndSettle();
  }

  testWidgets('a session nothing ever checked says exactly that', (
    tester,
  ) async {
    insertSession();
    await pump(tester);

    // The one that matters: an empty record is a gap in the record, and a
    // strip that drew nothing here would read as "checked, and fine".
    expect(find.text('No check recorded'), findsOneWidget);
  });

  testWidgets('a run still going is not a verdict', (tester) async {
    insertSession(status: SessionStatus.running);
    insertRun(id: 'v1');
    await pump(tester);

    expect(find.text('Checking…'), findsOneWidget);
    expect(find.text('No check recorded'), findsNothing);
  });

  testWidgets('a run nobody finished reads as unfinished once the session '
      'has ended', (tester) async {
    // `VerificationRun.isOpen` means "recording right now, **or** abandoned".
    // Once the session that owned it has ended, only the second reading is
    // left — the same rule `FollowUpReason.verificationAbandoned` states.
    insertSession(status: SessionStatus.completed);
    insertRun(id: 'v1');
    await pump(tester);

    expect(find.text('Check unfinished'), findsOneWidget);
    expect(find.text('Checking…'), findsNothing);
  });

  // A test each, on a fresh database: the three must be told apart from one
  // another as well as from the four states that are not verdicts at all.
  for (final (verdict, label) in const [
    (VerificationVerdict.pass, 'Checked: pass'),
    (VerificationVerdict.fail, 'Checked: fail'),
    (VerificationVerdict.inconclusive, 'Checked: inconclusive'),
  ]) {
    testWidgets('a ${verdict.name} reads as "$label"', (tester) async {
      insertSession();
      insertRun(id: 'v1', verdict: verdict);
      await pump(tester);

      expect(find.text(label), findsOneWidget);
      for (final other in SessionVerdictState.values) {
        if (other.label == label) continue;
        expect(find.text(other.label), findsNothing);
      }
    });
  }

  testWidgets('a verdict word this build cannot read is not made into one of '
      'the three', (tester) async {
    insertSession();
    insertRun(id: 'v1');
    // What a newer build's row looks like from here: finished, with a word
    // `VerificationVerdict.parse` returns null for.
    db.execute(
      'UPDATE verification_runs SET finished_at = ?, verdict = ? WHERE id = ?;',
      ['2026-01-02T03:10:00.000Z', 'flaky', 'v1'],
    );
    await pump(tester);

    expect(find.text('Verdict not recorded'), findsOneWidget);
    expect(find.text('Checked: pass'), findsNothing);
    expect(find.text('Check unfinished'), findsNothing);
  });

  testWidgets('the newest run supersedes the one before it', (tester) async {
    insertSession();
    insertRun(id: 'v1', verdict: VerificationVerdict.fail);
    insertRun(
      id: 'v2',
      startedAt: testTime.add(const Duration(hours: 1)),
      verdict: VerificationVerdict.pass,
    );
    await pump(tester);

    // A fail that was fixed and checked again reads as the pass it now is.
    expect(find.text('Checked: pass'), findsOneWidget);
    expect(find.text('Checked: fail'), findsNothing);
  });

  testWidgets('the verdict names the run and who graded it', (tester) async {
    insertSession();
    insertRun(
      id: 'v1',
      verdict: VerificationVerdict.fail,
      reason: 'The button was covered by the cookie banner.',
    );
    await pump(tester);

    final tooltip = tester.widget<Tooltip>(
      find.ancestor(
        of: find.text('Checked: fail'),
        matching: find.byType(Tooltip),
      ),
    );
    expect(tooltip.message, contains('the login page accepts a good password'));
    expect(tooltip.message, contains('The button was covered'));
    // The producer is the session under test, and saying so is the point of
    // attribution: a self-graded exam is worth less than a checked one.
    expect(tooltip.message, contains('by the author'));
  });

  testWidgets('the session bar\'s state line carries it too', (tester) async {
    insertSession();
    insertRun(id: 'v1', verdict: VerificationVerdict.pass);
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...fakeTerminalOverrides(database: db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          sessionDeliveryProvider.overrideWith((ref, _) async => delivery),
        ],
        child: const MaterialApp(
          home: Scaffold(body: DeliveryStateLine(sessionId: 's1')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // One fact, drawn by whichever host is showing the facts — not a second
    // copy that can come to disagree with the first.
    expect(find.text('Checked: pass'), findsOneWidget);
  });

  testWidgets('it survives the window matrix', (tester) async {
    insertSession();
    insertRun(
      id: 'v1',
      verdict: VerificationVerdict.inconclusive,
      reason: 'The device went away mid-run.',
    );
    await expectSurvivesWindowMatrix(
      tester,
      build: strip,
      because: 'the verdict is another fact in a row that already wraps',
    );
  });

  group('the rule itself', () {
    VerificationRun run({
      required String id,
      DateTime? startedAt,
      DateTime? finishedAt,
      VerificationVerdict? verdict,
    }) => VerificationRun(
      id: id,
      title: 'a check',
      target: const VerificationTarget.change(),
      startedAt: startedAt ?? testTime,
      finishedAt: finishedAt,
      verdict: verdict,
      artifactDirectory: 'C:/art/$id',
      sessionId: 's1',
    );

    test('no runs is not a verdict', () {
      expect(
        SessionVerdict.of(const [], sessionHasEnded: false).state,
        SessionVerdictState.notRecorded,
      );
    });

    test('an open run turns on whether the session is still live', () {
      final open = [run(id: 'v1')];
      expect(
        SessionVerdict.of(open, sessionHasEnded: false).state,
        SessionVerdictState.inProgress,
      );
      expect(
        SessionVerdict.of(open, sessionHasEnded: true).state,
        SessionVerdictState.unfinished,
      );
    });

    test('it counts the runs it did not report', () {
      final verdict = SessionVerdict.of([
        run(
          id: 'v2',
          startedAt: testTime.add(const Duration(hours: 1)),
          finishedAt: testTime.add(const Duration(hours: 2)),
          verdict: VerificationVerdict.pass,
        ),
        run(
          id: 'v1',
          finishedAt: testTime.add(const Duration(minutes: 1)),
          verdict: VerificationVerdict.fail,
        ),
      ], sessionHasEnded: true);

      expect(verdict.state, SessionVerdictState.pass);
      expect(verdict.run?.id, 'v2');
      expect(verdict.runCount, 2);
    });
  });
}
