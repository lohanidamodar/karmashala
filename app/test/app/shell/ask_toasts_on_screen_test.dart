import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/ask_toasts.dart';
import 'package:karmashala/src/features/explorer/application/agent_state_providers.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/explorer/application/session_context.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_ui/theme.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

/// **A toast is about its own session, and only one not on screen.** A
/// session with no pane of ours shows as its chat in place of the active tab;
/// the toasts used to judge "on screen" by that tab, as the phone banner did
/// before 2fea29d52.
void main() {
  late TestMachine db;
  late FakeDataServer server;
  late Override data;
  late ProviderContainer container;
  var asking = <String, NeedsYouSource>{};

  setUp(() async {
    asking = {};
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    data = await server.override();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation(id: 'pty'));
    container = ProviderContainer(
      overrides: [
        data,
        ...fakeTerminalOverrides(machine: db),
        needsYouProvider.overrideWith((ref) => asking),
      ],
    );
    addTearDown(container.dispose);
  });

  void asks(String id, String label) {
    server.attention.statusOf(
      id,
      AgentActivityStatus.awaitingApproval,
      sessionId: 'cli-$id',
      label: label,
      waiting: AgentWaitKind.approval,
      evidence: ['May $label run npm test?'],
    );
    asking = {
      ...asking,
      id: NeedsYouSource(label: label, imported: false),
    };
    container.invalidate(needsYouProvider);
  }

  testWidgets('the session shown as its chat is not toasted; the tab behind '
      'it is, by its own name', (tester) async {
    final terminals = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    terminals.openTab(TerminalProfile.powerShell);
    final paneId = container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .layout
        .panes
        .single;
    db.server.sessionRows
      ..insert(session(id: 'probe', agentInstallationId: 'pty', title: 'Probe'))
      ..updatePaneId('probe', paneId)
      ..insert(
        session(id: 'achiver', agentInstallationId: 'pty', title: 'achiver'),
      );
    // No pane of ours: it is shown in place of the tab, which stays active.
    container.read(selectedSessionIdProvider.notifier).select('achiver');

    asks('achiver', 'achiver');
    asks('probe', 'Probe fixes');

    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: ShellAskToasts(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('ask-toast:achiver')), findsNothing);
    expect(find.byKey(const ValueKey('ask-toast:probe')), findsOneWidget);
    expect(find.text('Probe fixes needs you'), findsOneWidget);
    expect(find.text('May Probe fixes run npm test?'), findsOneWidget);

    // Open brings the toast's own session on screen, and its toast goes.
    await tester.tap(find.text('Open'));
    await tester.pump();
    expect(container.read(onScreenSessionIdProvider), 'probe');
    expect(find.byKey(const ValueKey('ask-toast:probe')), findsNothing);
    expect(find.byKey(const ValueKey('ask-toast:achiver')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
