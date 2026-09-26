import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/stream.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_handoff_service.dart';
import 'package:karmashala/src/features/sessions/application/session_notice.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala/src/features/sessions/data/session_recap_dao.dart';
import 'package:karmashala/src/features/sessions/presentation/agent_status_badge.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/transcript.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_terminal_core/profiles.dart';

import '../../app/minimum_window_matrix_test.dart' show noProcessOverrides;
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';
import '../terminal/fake_instance.dart';

/// The conversation's footer — approval, delivery, notice, composer — and the
/// recap above it must leave the transcript room at every window and pane size.
void main() {
  Future<void> run(
    WidgetTester tester, {
    required List<WindowCell> matrix,
    bool busy = true,
    Future<void> Function(WidgetTester tester)? check,
  }) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(
      db,
    ).insert(agentInstallation(agentId: AgentIds.claudeCode));
    final dao = SessionDao(db)
      ..insert(
        Session(
          id: 's1',
          repositoryId: 'r1',
          agentInstallationId: agentInstallation(
            agentId: AgentIds.claudeCode,
          ).id,
          title: 'Session',
          useWorktree: true,
          worktree: const EnvironmentPath(
            environmentId: 'windows',
            path: r'C:\src\.karmashala-worktrees\app-s1',
          ),
          status: SessionStatus.running,
          createdAt: testTime,
          surface: SessionSurface.external,
        ),
      );
    if (busy) {
      SessionRecapDao(db).write(
        SessionRecap(
          sessionId: 's1',
          text: List.filled(
            8,
            'The agent refactored the login flow and moved token refresh.',
          ).join(' '),
          agentId: AgentIds.claudeCode,
          turnCount: 3,
          writtenAt: testTime,
        ),
      );
    }
    final events = [
      for (var i = 0; i < 6; i++)
        SessionEvent(
          id: i + 1,
          sessionId: 's1',
          seq: i,
          type: i.isEven
              ? SessionEventTypes.userMessage
              : SessionEventTypes.agentMessage,
          payload: '{"text":"turn $i"}',
          createdAt: testTime,
        ),
    ];

    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        ...noProcessOverrides(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        agentRegistryProvider.overrideWithValue(AgentRegistry.builtIn),
        availableSystemTerminalsProvider.overrideWith((ref) async => const []),
        sessionTranscriptProvider.overrideWith(
          (ref, id) => Stream.value(events),
        ),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => Stream.value(
            AgentStatusReport(
              agentId: AgentIds.claudeCode,
              sessionId: id,
              status: busy
                  ? AgentActivityStatus.awaitingApproval
                  : AgentActivityStatus.idle,
              source: AgentStatusSource.terminalGrid,
              observedAt: testTime,
              evidence: const [
                'Do you want to run this command?',
                '  git push --force-with-lease origin agent/login',
                '❯ 1. Yes',
                '  2. No, and tell Claude what to do differently',
              ],
              waiting: AgentWaitKind.approval,
            ),
          ),
        ),
        sessionDeliveryProvider.overrideWith(
          (ref, _) async => const SessionDelivery(
            branch: 'session/fix-the-login',
            baseBranch: 'origin/main',
            hasRemote: true,
            dirtyFiles: 2,
            aheadOfBase: 3,
            hasWorktree: true,
          ),
        ),
        sessionContinuationProvider.overrideWith(
          (ref, _) => SessionContinuation(
            targets: const [],
            plan: SessionForkPlan.decide(
              descriptor: null,
              agentName: 'Test CLI',
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final opened = container
        .read(terminalSessionsControllerProvider.notifier)
        .openAgentTab(
          const AgentPaneLaunch(
            agentId: AgentIds.claudeCode,
            executable: 'claude',
            sessionId: 's1',
            title: 'Session',
          ),
        );
    dao.updatePaneId('s1', opened.paneId);

    await expectSurvivesWindowMatrix(
      tester,
      matrix: matrix,
      checkFocus: false,
      checkSemantics: false,
      build: () {
        if (busy) {
          container
              .read(sessionNoticesProvider.notifier)
              .post(
                's1',
                SessionNotice(
                  message:
                      'Workspace · On request — applies the next time this '
                      'session is launched or resumed, not to the agent '
                      'running now.',
                  action: SessionNoticeAction(
                    label: 'Restart to apply',
                    onPressed: () {},
                  ),
                ),
              );
        }
        return UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: SessionTranscriptView(sessionId: 's1')),
          ),
        );
      },
      warmUp: busy
          ? (tester) async {
              await tester.enterText(
                find.byType(TextField),
                List.generate(12, (i) => 'line $i').join('\n'),
              );
              await tester.pump();
              await check?.call(tester);
            }
          : check,
    );
  }

  const paneAtMinimum = WindowCell('720x454 pane', Size(720, 454));
  const paneAtMinimumLarge = WindowCell(
    '720x454 pane @1.3x',
    Size(720, 454),
    textScale: 1.3,
  );
  const stackedSplit = WindowCell('720x215 stacked split', Size(720, 215));
  const narrowPane = WindowCell('360x454 pane', Size(360, 454));

  testWidgets('an idle conversation fits half a stacked split', (tester) async {
    await run(
      tester,
      matrix: const [...windowMatrix, paneAtMinimum, stackedSplit],
      busy: false,
    );
  });

  testWidgets('the session header grows with the text scale', (tester) async {
    await run(
      tester,
      matrix: const [
        WindowCell('1440x900 @2x text', Size(1440, 900), textScale: 2),
      ],
      busy: false,
      check: (tester) async {
        // A cross-axis clip reports no overflow, so the label's own height is
        // compared with the row that holds it.
        final label = tester.renderObject<RenderBox>(
          find
              .descendant(
                of: find.byType(AgentStatusBadge),
                matching: find.byType(RichText),
              )
              .last,
        );
        final header = tester.getRect(find.byType(Divider).first).top;
        expect(
          label.getMaxIntrinsicHeight(double.infinity),
          lessThanOrEqualTo(header),
        );
      },
    );
  });

  testWidgets(
    'approval, recap, notice and a 12-line draft leave the transcript room',
    (tester) async {
      await run(
        tester,
        matrix: const [
          ...windowMatrix,
          paneAtMinimum,
          paneAtMinimumLarge,
          stackedSplit,
          narrowPane,
          WindowCell('240x560 side panel', Size(240, 560)),
          WindowCell('240x560 @1.3x', Size(240, 560), textScale: 1.3),
        ],
      );
    },
  );

  testWidgets('the transcript keeps at least a quarter of its height', (
    tester,
  ) async {
    await run(
      tester,
      matrix: const [minimumWindowLargeText, paneAtMinimum],
      check: (tester) async {
        final whole = tester.getSize(find.byType(ChatTranscriptView)).height;
        final list = tester.getSize(find.byType(ListView)).height;
        expect(list, greaterThanOrEqualTo(whole / 4));
      },
    );
  });
}
