import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_runtime/instances.dart';
import 'package:xterm2/xterm.dart' show Terminal;

import '../../features/terminal/fake_instance.dart';
import '../../support/desktop_client.dart';
import '../../support/fake_data_server.dart';
import '../../support/test_machine.dart';

/// Opening the app starts nothing on any machine (owner, 2026-10-01): with an
/// SSH profile as the default, every launch started a new shell on the box and
/// left the last one running there with no pane.
void main() {
  testWidgets('a workbench that starts with no tabs opens no terminal and '
      'shows its empty state', (tester) async {
    final server = FakeDataServer();
    final built = <String>[];
    TerminalInstance recording({
      required String id,
      required TerminalProfile profile,
      String? workingDirectory,
      String? restoredScrollback,
      bool shellIntegration = false,
      AgentPaneLaunch? agentLaunch,
      Terminal? adoptTerminal,
    }) {
      built.add(profile.id);
      return defaultFakeInstanceFactory(id: id, profile: profile);
    }

    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(
          machine: TestMachine(),
          data: await server.override(),
          instanceFactory: recording,
        ),
        // A desktop that hosts its server: where the automatic open used to
        // run.
        clientCapabilitiesProvider.overrideWithValue(desktopClient()),
      ],
    );
    addTearDown(container.dispose);
    // The owner's default: a terminal on an SSH machine.
    expect(container.read(clientCapabilitiesProvider).hostsServer, isTrue);
    container
        .read(settingsControllerProvider.notifier)
        .setDefaultTerminalProfile(TerminalProfile.sshId('do'));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: WorkbenchView())),
      ),
    );
    // The empty state from the first frame — no "Opening terminal…" between.
    expect(find.text('No terminal open'), findsOneWidget);
    await tester.pumpAndSettle();

    expect(container.read(terminalSessionsControllerProvider).tabs, isEmpty);
    expect(built, isEmpty, reason: 'no pane was built');
    expect(server.terminals.opened, isEmpty, reason: 'no terminals.open sent');
    expect(find.text('No terminal open'), findsOneWidget);
  });
}
