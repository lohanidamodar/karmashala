import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/sessions/application/background_runs_providers.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_activity_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/working_line.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// **The composer stays in sight**: a session with 21 background runs and a
/// running turn, on a phone with the keyboard up and on a desktop. The runs
/// and the transcript give up height; the box being typed in never does.
void main() {
  late TestMachine db;
  late FakeDataServer server;

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(
        id: 'acp',
        agentId: AgentIds.claudeAcp,
        path: r'C:\Users\me\.bin\claude-agent-acp.exe',
      ),
    );
    server.sessionWork
      ..running.add('acp-1')
      ..busy.add('acp-1');
    db.server.sessionRows.insert(
      session(
        id: 'acp-1',
        agentInstallationId: 'acp',
        status: SessionStatus.running,
      ),
    );
  });

  final runs = [
    for (var i = 0; i < 21; i++)
      SessionBackgroundRun(
        run: BackgroundRun(
          id: 'b$i',
          kind: BackgroundRunKind.command,
          state: i < 8
              ? BackgroundRunState.running
              : BackgroundRunState.completed,
          description: 'Background command $i',
          endedAt: i < 8 ? null : testTime.subtract(Duration(seconds: i)),
        ),
        startedAt: testTime.subtract(Duration(hours: 16, minutes: i)),
      ),
  ];

  Future<void> pump(
    WidgetTester tester, {
    required Size size,
    double keyboard = 0,
    bool? folded,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        ...fakeTerminalOverrides(machine: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        serverOfferProvider.overrideWithValue(
          const ServerOffer(
            sameMachine: true,
            serverOs: 'windows',
            features: {'sessions.send', 'sessions.interrupt'},
          ),
        ),
        sessionRunningOnHostProvider.overrideWithValue((_) => true),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => Stream.value(
            AgentStatusReport(
              agentId: AgentIds.claudeAcp,
              sessionId: id,
              status: AgentActivityStatus.working,
              observedAt: testTime,
              source: AgentStatusSource.protocol,
            ),
          ),
        ),
        sessionChatTranscriptProvider.overrideWith(
          (ref, id) => Stream.value([
            for (var i = 0; i < 40; i++)
              TranscriptMessage(role: 'assistant', text: 'Line $i'),
          ]),
        ),
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        sessionDeliveryProvider.overrideWith(
          (ref, _) async => SessionDelivery.unknown,
        ),
        sessionOutstandingCallsProvider.overrideWith(
          (ref, _) => SessionActivity([
            OutstandingCall(
              summary: 'Bash(flutter test)',
              toolName: 'Bash',
              startedAt: testTime,
            ),
          ]),
        ),
        sessionBackgroundRunsProvider.overrideWith((ref, _) => runs),
      ],
    );
    addTearDown(container.dispose);
    if (folded != null) {
      container
          .read(backgroundRunsFoldedProvider.notifier)
          .set('acp-1', folded: folded);
    }
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            // The phone's top bar and session bar.
            appBar: AppBar(title: const Text('Session')),
            body: const SessionTranscriptView(sessionId: 'acp-1'),
          ),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  void expectInSight(WidgetTester tester, Finder finder, double visibleBottom) {
    final rect = tester.getRect(finder);
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(visibleBottom));
    expect(rect.height, greaterThan(20));
  }

  for (final folded in [null, false]) {
    final how = folded == null ? 'as it starts' : 'unfolded';
    testWidgets('on a phone with the keyboard up, 21 runs $how leave the '
        'composer and the Stop in sight', (tester) async {
      const size = Size(390, 844);
      await pump(tester, size: size, keyboard: 300, folded: folded);

      expect(tester.takeException(), isNull);
      final composer = find.byType(TextField).last;
      expectInSight(tester, composer, size.height - 300);
      expectInSight(tester, find.byType(WorkingLine), size.height - 300);

      await tester.enterText(composer, 'what I am typing');
      await tester.pump();
      expect(find.text('what I am typing'), findsOneWidget);
      expectInSight(tester, composer, size.height - 300);
    });

    testWidgets('on a desktop, 21 runs $how leave the composer in sight', (
      tester,
    ) async {
      const size = Size(1440, 900);
      await pump(tester, size: size, folded: folded);

      expect(tester.takeException(), isNull);
      expectInSight(tester, find.byType(TextField).last, size.height);
      expectInSight(tester, find.byType(WorkingLine), size.height);
    });
  }
}
