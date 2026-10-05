import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_handoff_service.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

/// **The session bar leads with its session's agent**, so it is clear which

/// The pane's status line at the widths a desktop window gives it: the facts
/// and the controls each keep to their own room. "Not running" once ran on
/// under "Stats" at a 1480-wide window.
void main() {
  late TestMachine db;
  late ProviderContainer container;

  setUp(() async {
    db = TestMachine();
    final server = FakeDataServer()..runsOn(db);
    final Override data = await server.override();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(
        id: 'cx',
        agentId: AgentIds.codex,
        path: r'C:\Users\me\.bin\codex.exe',
      ),
    );
    db.server.sessionRows.insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'cx',
        title: 'Status line',
        useWorktree: false,
        status: SessionStatus.running,
        createdAt: testTime,
      ),
    );
    container = ProviderContainer(
      overrides: [
        data,
        ...fakeTerminalOverrides(machine: db),
        sessionTranscriptProvider.overrideWith(
          (ref, id) => Stream.value(const []),
        ),
        sessionChatTranscriptProvider.overrideWith(
          (ref, id) => Stream.value(const <TranscriptMessage>[]),
        ),
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        sessionDeliveryProvider.overrideWith(
          (ref, _) async => const SessionDelivery(
            branch: 'karmashala/a-branch-named-at-length-for-the-line',
            baseBranch: 'main',
          ),
        ),
        sessionContinuationProvider.overrideWith(
          (ref, _) => SessionContinuation(
            targets: const [],
            plan: SessionForkPlan.decide(descriptor: null, agentName: 'Codex'),
          ),
        ),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => Stream.value(
            AgentStatusReport(
              agentId: AgentIds.codex,
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
  });

  for (final size in const [Size(1480, 953), Size(1180, 953), Size(720, 560)]) {
    testWidgets('at ${size.width.toInt()}×${size.height.toInt()}', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      container.read(selectedSessionIdProvider.notifier).select('s1');
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              // The activity strip and sidebar beside the workbench.
              body: Row(
                children: [
                  SizedBox(width: 368),
                  Expanded(child: WorkbenchView()),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final word = find.descendant(
        of: find.byKey(const ValueKey('delivery-stage')),
        matching: find.byType(Text),
      );
      expect(word, findsOneWidget);
      // The word's last glyph is the word's to hit, not a control's drawn
      // over it: nothing in the bar lies over the facts.
      final paragraph = tester.renderObject<RenderBox>(word);
      final rect = tester.getRect(word);
      final hits = tester.hitTestOnBinding(
        Offset(rect.right - 1, rect.center.dy),
      );
      expect(
        hits.path.map((entry) => entry.target),
        contains(paragraph),
        reason:
            'a control covers the end of "${tester.widget<Text>(word).data}"',
      );
      expect(tester.takeException(), isNull);
    });
  }
}
