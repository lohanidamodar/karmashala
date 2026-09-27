import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show SshDeployAction;
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/environments/application/environment_health.dart';
import 'package:karmashala/src/features/environments/application/system_health.dart';
import 'package:karmashala/src/features/environments/application/system_health_service.dart';
import 'package:karmashala/src/features/environments/presentation/environment_health_dialog.dart';
import 'package:karmashala/src/features/remote/application/remote_access_controller.dart';
import 'package:karmashala/src/features/ssh/application/ssh_terminal_opener.dart';
import 'package:karmashala/src/features/ssh/presentation/host_install_panel.dart';
import 'package:karmashala/src/features/ssh/presentation/ssh_hosts_section.dart';
import 'package:karmashala_host_protocol/host_access.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/system_health_fakes.dart';
import '../../support/window_matrix.dart';
import '../terminal/fake_instance.dart';
import '../../support/fake_data_server.dart';
import '../../support/test_machine.dart';

class _Access extends RemoteAccessController {
  _Access(super.ref);

  @override
  Future<void> sync() async {}
}

/// The host line is drawn where the machine is: its card in Settings ›
/// Environments, and its row in System health. One panel, two places, every
/// reading the server's (slice 5d).
void main() {
  late TestMachine db;
  late FakeDataServer server;
  late Override data;

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer();
    server.environmentRows
      ..upsert(windowsEnv())
      ..upsert(sshEnvFixture(name: boxHost.name));
    server.sshHostRows.upsert(boxHost);
    data = await server.override();
  });

  Widget scope(Widget body) => ProviderScope(
    overrides: [
      ...fakeTerminalOverrides(machine: db, data: data),
      clockProvider.overrideWithValue(FixedClock(testTime)),
      idGeneratorProvider.overrideWithValue(SequentialIdGenerator()),
      remoteAccessControllerProvider.overrideWith(_Access.new),
      sshTerminalOpenerProvider.overrideWithValue((host, {typed}) => true),
      systemHealthProvider.overrideWith(
        () => FixedSystemHealthController(
          SystemHealthReport(
            checkedAt: testTime,
            checks: const [],
            environments: [
              EnvironmentHealth(
                environment: windowsEnv(),
                level: HealthLevel.healthy,
                summary: '1 coding agent ready.',
                installations: const [],
              ),
              EnvironmentHealth(
                environment: sshEnvFixture(name: boxHost.name),
                level: HealthLevel.healthy,
                summary: '1 coding agent ready.',
                installations: const [],
              ),
            ],
          ),
        ),
      ),
    ],
    child: MaterialApp(home: Scaffold(body: body)),
  );

  Finder inPanel(String label) => find.descendant(
    of: find.byType(HostInstallPanel),
    matching: find.text(label),
  );

  Future<void> pressInPanel(WidgetTester tester, String label) async {
    await tester.ensureVisible(inPanel(label));
    // The scroll lands on the next frame; a tap before it aims at where the
    // button was.
    await tester.pump();
    await tester.tap(inPanel(label));
    await tester.pumpAndSettle();
  }

  Future<void> tall(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('the SSH host card reads the host and installs it', (
    tester,
  ) async {
    await tall(tester);
    await tester.pumpWidget(
      scope(const SingleChildScrollView(child: SshHostsSection())),
    );

    expect(
      find.text('Karmashala host: not checked since this launch'),
      findsOneWidget,
    );
    expect(
      server.sshWork.deploys,
      isEmpty,
      reason: 'drawing the card asks nothing',
    );

    server.sshWork.onDeploy = (request) => server.sshWork.boxReading(
      request.action == SshDeployAction.check
          ? HostInstallState.notInstalled
          : HostInstallState.installed,
    );
    await pressInPanel(tester, 'Check');
    expect(find.text('Karmashala host: not installed'), findsOneWidget);
    await pressInPanel(tester, 'Install');
    expect(
      find.text('Karmashala host: installed 1.25.0 (running)'),
      findsOneWidget,
    );
    // The card's own Remove still forgets the machine; the host's is Uninstall.
    expect(find.widgetWithText(TextButton, 'Remove'), findsOneWidget);
    expect(inPanel('Uninstall'), findsOneWidget);
  });

  testWidgets('System health has the same line on the machine\'s row, and on '
      'no other', (tester) async {
    await tall(tester);
    await tester.pumpWidget(scope(const EnvironmentHealthDialog()));
    await tester.pump();

    expect(find.byType(HostInstallPanel), findsOneWidget);
    expect(
      server.sshWork.deploys,
      isEmpty,
      reason: 'opening the panel asks nothing',
    );

    server.sshWork.onDeploy = (_) =>
        server.sshWork.boxReading(HostInstallState.notInstalled);
    await pressInPanel(tester, 'Check');
    expect(find.text('Karmashala host: not installed'), findsOneWidget);
    expect(inPanel('Install'), findsOneWidget);
  });

  testWidgets('the System health row is the compact one: what moves things on, '
      'and where the rest is', (tester) async {
    await tall(tester);
    await tester.pumpWidget(scope(const EnvironmentHealthDialog()));
    await tester.pump();

    await pressInPanel(tester, 'Check');

    expect(
      find.text('Karmashala host: installed 1.25.0 (running)'),
      findsOneWidget,
    );
    // Ending sessions and deleting a bundle are not one click from a health
    // reading; they are on the card.
    expect(inPanel('Stop'), findsNothing);
    expect(inPanel('Uninstall'), findsNothing);
    expect(inPanel('Reinstall'), findsNothing);
  });

  testWidgets('the System health row survives the window matrix with a step '
      'that needs sudo', (tester) async {
    server.sshWork.onDeploy = (_) => server.sshWork.boxReading(
      HostInstallState.notInstalled,
      deployment: HostDeployment(
        status: HostDeploymentStatus.cannotInstall,
        observedAt: testTime,
        reason: 'do-box has no `tar`. Nothing was uploaded.',
        privileged: const PrivilegedCommand(
          command: 'sudo apt-get install -y tar',
          does: 'Installs tar on do-box.',
          why: 'It needs root.',
        ),
      ),
    );
    await expectSurvivesWindowMatrix(
      tester,
      build: () => scope(const EnvironmentHealthDialog()),
      warmUp: (tester) async {
        await pressInPanel(tester, 'Check');
        expect(find.textContaining('on do-box\'s card'), findsOneWidget);
        expect(find.text('Open a terminal on do-box'), findsNothing);
      },
      because: 'the row shares a 620x420 list with every other check',
    );
  });
}
