import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala_session/events.dart';
import 'package:agent_cli/stream.dart';
import 'package:karmashala_ui/transcript.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../../support/window_matrix.dart';
import '../terminal/fake_instance.dart';

void main() {
  testWidgets('renders user and agent messages from the transcript', (
    tester,
  ) async {
    final events = [
      SessionEvent(
        id: 1,
        sessionId: 's1',
        seq: 0,
        type: SessionEventTypes.userMessage,
        payload: '{"text":"hello"}',
        createdAt: testTime,
      ),
      SessionEvent(
        id: 2,
        sessionId: 's1',
        seq: 1,
        type: SessionEventTypes.agentMessage,
        payload: '{"text":"Echo: hello"}',
        createdAt: testTime,
      ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionTranscriptProvider.overrideWith(
            (ref, id) => Stream.value(events),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SessionTranscriptView(sessionId: 's1')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Message bodies render as (selectable) Markdown, CLI-style.
    expect(find.byType(MarkdownMessage), findsNWidgets(2));
    expect(find.textContaining('Echo: hello'), findsOneWidget);
    // Role eyebrows are uppercased.
    expect(find.text('YOU'), findsOneWidget);
    expect(find.text('AGENT'), findsOneWidget);
    // The input is always usable; when idle it invites continuing the session.
    expect(find.text('Type to continue this session…'), findsOneWidget);
  });

  testWidgets('a native session shows the command a tool call ran', (
    tester,
  ) async {
    // The engine records `tool.call` with the adapter's `name`/`input`
    // (`parseClaudeMessage`), and the view used to drop it — so a session's
    // commands were invisible in the one place the owner reads them.

    final events = [
      SessionEvent(
        id: 1,
        sessionId: 's1',
        seq: 0,
        type: SessionEventTypes.toolCall,
        payload: '{"name":"Bash","input":{"command":"git status --short"}}',
        createdAt: testTime,
      ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionTranscriptProvider.overrideWith(
            (ref, id) => Stream.value(events),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SessionTranscriptView(sessionId: 's1')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('BASH'), findsOneWidget);
    expect(find.text('git status --short'), findsOneWidget);
  });

  /// A session run by an agent whose conversation we cannot read (Antigravity
  /// has an adapter and no readable store), optionally in a pane of ours.
  ///
  /// This is the pair the Loop 85 fallback created: the workbench sends a
  /// session with no terminal *here*, so what this view says about the terminal
  /// has to be true of the session in front of it.
  Future<void> pumpNoChatAgent(
    WidgetTester tester, {
    required bool inAPane,
    List<SystemTerminal> terminals = const [],
  }) async {
    final db = TestMachine();
    final server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(agentId: AgentIds.antigravity),
    );
    final dao = db.server.sessionRows
      ..insert(
        Session(
          id: 's1',
          repositoryId: 'r1',
          agentInstallationId: 'a1',
          title: 'Session',
          useWorktree: false,
          status: SessionStatus.running,
          createdAt: testTime,
          surface: SessionSurface.pane,
        ),
      );

    final container = ProviderContainer(
      overrides: [
        await server.override(),
        ...fakeTerminalOverrides(machine: db),
        availableSystemTerminalsProvider.overrideWith((ref) async => terminals),
        sessionDeliveryProvider.overrideWith(
          (ref, _) async => SessionDelivery.unknown,
        ),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => Stream.value(
            AgentStatusReport(
              agentId: AgentIds.antigravity,
              sessionId: id,
              status: AgentActivityStatus.idle,
              observedAt: testTime,
              source: AgentStatusSource.none,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    if (inAPane) {
      final terminals = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      terminals.openTab(TerminalProfile.powerShell);
      dao.updatePaneId(
        's1',
        container
            .read(terminalSessionsControllerProvider)
            .activeTab!
            .layout
            .panes
            .single,
      );
    }

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: SessionTranscriptView(sessionId: 's1')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('an agent with no chat view points at its terminal', (
    tester,
  ) async {
    await pumpNoChatAgent(tester, inAPane: true);

    expect(find.textContaining('Its terminal is the session'), findsOneWidget);
  });

  testWidgets('the external-terminal menu draws the house menu row', (
    tester,
  ) async {
    // It was a hand-rolled 32px Row beside menus built from `DesktopMenuItem`
    // — same height, different gutter, different type ramp.
    await pumpNoChatAgent(
      tester,
      inAPane: true,
      terminals: const [
        SystemTerminal(
          kind: SystemTerminalKind.windowsTerminal,
          label: 'Windows Terminal',
          executable: 'wt.exe',
        ),
      ],
    );

    await tester.tap(find.byIcon(AppIcons.arrowSquareOut));
    await tester.pumpAndSettle();

    expect(
      find.byType(DesktopMenuItem<SystemTerminal>),
      findsOneWidget,
      reason: 'the row is the shared one, not a Row of its own',
    );
    expect(find.text('Open in Windows Terminal'), findsOneWidget);
    expect(
      tester.getSize(find.byType(DesktopMenuItem<SystemTerminal>)).height,
      Chrome.menuRow,
    );
  });

  testWidgets('the Tab ring closes when the conversation scrolls', (
    tester,
  ) async {
    // Bug 3. The stops of the *scrolling* transcript and those of the fixed
    // footer under it used to sort together by rect, so tabbing to a row below
    // the fold scrolled the list under the traversal policy — every remaining
    // row moved up past footer stops it had already handed out, and the next
    // Tab returned one of them. Six turns is enough to overflow 720x560; each
    // carries a "Copy message" and a "Save as note" button, which are the
    // stops that move.

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

    await expectSurvivesWindowMatrix(
      tester,
      build: () => ProviderScope(
        overrides: [
          sessionTranscriptProvider.overrideWith(
            (ref, id) => Stream.value(events),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SessionTranscriptView(sessionId: 's1')),
        ),
      ),
      // Scrolled back to the oldest turn, which is where a reader who wants
      // the beginning of a conversation is. The view opens pinned to the
      // bottom, and from there Tab never has to scroll forward at all.
      warmUp: (tester) async {
        await tester.drag(find.byType(ListView), const Offset(0, 2000));
        await tester.pumpAndSettle();
      },
      because:
          'a conversation taller than the window is the ordinary case, and '
          'Tab has to come back to where it started in it',
    );
  });

  testWidgets('...but not when there is no terminal left to point at', (
    tester,
  ) async {
    // The two fallbacks used to fight: the workbench lands a session with no
    // pane here *because* it has no terminal, and this view answered "its
    // terminal is the session" — sending the user to a surface that is not
    // there.
    await pumpNoChatAgent(tester, inAPane: false);

    expect(find.textContaining('Its terminal is the session'), findsNothing);
    expect(find.textContaining('no terminal open'), findsOneWidget);
    expect(find.textContaining('Type below to run it again'), findsOneWidget);
  });
}
