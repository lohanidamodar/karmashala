import 'package:chitragupta/src/features/agents/domain/agent_descriptor.dart';
import 'package:chitragupta/src/features/sessions/application/handoff_providers.dart';
import 'package:chitragupta/src/features/sessions/application/session_actions.dart';
import 'package:chitragupta/src/features/sessions/application/session_handoff_service.dart';
import 'package:chitragupta/src/features/sessions/domain/handoff_action.dart';
import 'package:chitragupta/src/features/sessions/domain/session_fork.dart';
import 'package:chitragupta/src/features/sessions/presentation/handoff_actions_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the row sent, instead of a real agent — the point of the design is that
/// a button is a message, so the assertion is on the text.
class _Recorder {
  final sent = <String>[];
  Object? throwOnSend;
}

class _RecordingActions extends SessionActions {
  _RecordingActions(super.ref, this._recorder);

  final _Recorder _recorder;

  @override
  Future<void> continueSession(String sessionId, String text) async {
    final failure = _recorder.throwOnSend;
    if (failure != null) throw failure;
    _recorder.sent.add(text);
  }
}

void main() {
  late _Recorder actions;

  setUp(() => actions = _Recorder());

  /// Nowhere to continue to, which is the shape these tests are about: they
  /// assert the *prompt* buttons, and "Continue with…" is not one.
  final noContinuation = SessionContinuation(
    targets: const [],
    plan: SessionForkPlan.decide(descriptor: null, agentName: 'Test CLI'),
  );

  Future<void> pumpRow(
    WidgetTester tester,
    HandoffRepoState? state, {
    SessionContinuation? continuation,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionHandoffStateProvider.overrideWith((ref, _) async => state),
          sessionContinuationProvider.overrideWith(
            (ref, _) => continuation ?? noContinuation,
          ),
          sessionActionsProvider.overrideWith(
            (ref) => _RecordingActions(ref, actions),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: HandoffActionsRow(sessionId: 's1')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('offers the whole row when repository state is unknown', (
    tester,
  ) async {
    await pumpRow(tester, null);

    expect(find.text('Commit'), findsOneWidget);
    expect(find.text('Open PR'), findsOneWidget);
    expect(find.text('Run tests'), findsOneWidget);
  });

  testWidgets('hides the PR action on the default branch', (tester) async {
    await pumpRow(
      tester,
      const HandoffRepoState(
        branch: 'main',
        hasRemote: true,
        defaultBranch: 'main',
      ),
    );

    expect(find.text('Open PR'), findsNothing);
    expect(find.text('Commit'), findsOneWidget);
    expect(find.text('Run tests'), findsOneWidget);
  });

  testWidgets('hides the PR action when there is no remote', (tester) async {
    await pumpRow(
      tester,
      const HandoffRepoState(branch: 'work', hasRemote: false),
    );

    expect(find.text('Open PR'), findsNothing);
  });

  testWidgets('a button sends its prompt verbatim, with no dialog', (
    tester,
  ) async {
    await pumpRow(
      tester,
      const HandoffRepoState(
        branch: 'work',
        hasRemote: true,
        defaultBranch: 'main',
        commitsAhead: 2,
      ),
    );

    await tester.tap(find.text('Open PR'));
    await tester.pumpAndSettle();

    expect(actions.sent, [HandoffAction.pullRequest.prompt]);
    // No confirmation step stands between the click and the send.
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('each button sends its own prompt', (tester) async {
    await pumpRow(tester, null);

    await tester.tap(find.text('Commit'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run tests'));
    await tester.pumpAndSettle();

    expect(actions.sent, [
      HandoffAction.commit.prompt,
      HandoffAction.runTests.prompt,
    ]);
  });

  testWidgets('a failure that means the prompt never left shows a snackbar', (
    tester,
  ) async {
    await pumpRow(tester, null);
    actions.throwOnSend = StateError('The agent for this session is gone.');

    await tester.tap(find.text('Commit'));
    await tester.pumpAndSettle();

    expect(find.text('The agent for this session is gone.'), findsOneWidget);
    expect(actions.sent, isEmpty);
  });

  testWidgets('offers Continue with… when there is somewhere to go', (
    tester,
  ) async {
    const target = AgentDescriptor(
      id: 'x',
      displayName: 'X CLI',
      binaries: AgentBinaries(windows: ['x'], posix: ['x']),
      launch: AgentLaunchSpec(
        acceptsPromptArgument: true,
        fork: AgentForkSupport.native(
          resume: AgentResume.flag('--resume'),
          evidence: 'x --help',
        ),
      ),
    );
    await pumpRow(
      tester,
      null,
      continuation: SessionContinuation(
        targets: const [],
        plan: SessionForkPlan.decide(
          descriptor: target,
          agentName: 'X CLI',
          externalSessionId: 'id',
        ),
      ),
    );
    expect(find.text('Continue with…'), findsOneWidget);
  });

  testWidgets('withholds it when the session has nowhere to go', (
    tester,
  ) async {
    // An agent that declares no fork and no reachable target: the entry is
    // absent rather than present-and-broken.
    await pumpRow(tester, null);
    expect(find.text('Continue with…'), findsNothing);
    // The prompt buttons are unaffected — the two halves of the row are
    // independent.
    expect(find.text('Commit'), findsOneWidget);
  });
}
