import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/remote/application/remote_access_controller.dart';
import 'package:karmashala/src/features/remote/application/ssh_relays.dart';
import 'package:karmashala/src/features/ssh/presentation/host_install_panel.dart';
import 'package:karmashala/src/features/ssh/application/ssh_terminal_opener.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host_protocol/host_access.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../../support/window_matrix.dart';
import '../terminal/fake_instance.dart';

class _Access extends RemoteAccessController {
  _Access(super.ref);

  @override
  Future<void> sync() async {}
}

final _arm = HostPlatform(
  operatingSystem: 'linux',
  architecture: 'arm64',
  libc: HostLibc.glibc,
  observedAt: testTime,
);

/// The host on a box, as its card shows it (slice 5d): every reading is the
/// server's — asked with `ssh.deploy` and shown as it came back; the app
/// neither dials the box nor decides anything about it. The deploy's own
/// logic is `karmashala_ssh_host`'s and the server's tests'.
void main() {
  late TestMachine db;
  late FakeDataServer server;
  late DataClient data;
  late List<({String host, String? typed})> terminals;

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer(clock: () => testTime);
    data = await server.connect();
    terminals = [];
  });

  ProviderContainer containerFor() {
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(machine: db),
        dataClientProvider.overrideWithValue(data),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        remoteAccessControllerProvider.overrideWith(_Access.new),
        sshTerminalOpenerProvider.overrideWithValue((host, {typed}) {
          terminals.add((host: host.name, typed: typed));
          return true;
        }),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Widget panel(ProviderContainer container, {bool debugRun = false}) =>
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: HostInstallPanel(host: boxHost, debugRun: debugRun),
              ),
            ),
          ),
        ),
      );

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    bool debugRun = false,
  }) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = containerFor();
    await tester.pumpWidget(panel(container, debugRun: debugRun));
    return container;
  }

  Future<void> press(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  /// What the server answers to each action from now on.
  void answer(HostInstallReading Function(SshDeploy request) reading) =>
      server.sshWork.onDeploy = reading;

  testWidgets('nothing is claimed before somebody asks, and nothing is asked '
      'on its own', (tester) async {
    await pump(tester);
    await tester.pumpAndSettle();

    expect(
      find.text('Karmashala host: not checked since this launch'),
      findsOneWidget,
    );
    expect(server.sshWork.deploys, isEmpty);
  });

  testWidgets('Check asks the server; Install is the server\'s deploy', (
    tester,
  ) async {
    answer(
      (request) => request.action == SshDeployAction.check
          ? server.sshWork.boxReading(HostInstallState.notInstalled)
          : server.sshWork.boxReading(HostInstallState.installed),
    );
    await pump(tester);

    await press(tester, 'Check');
    expect(find.text('Karmashala host: not installed'), findsOneWidget);
    expect(server.sshWork.deploys.single.action, SshDeployAction.check);

    await press(tester, 'Install');
    expect(
      find.text('Karmashala host: installed 1.25.0 (running)'),
      findsOneWidget,
    );
    expect(server.sshWork.deploys.last.action, SshDeployAction.install);
    expect(server.sshWork.deploys.last.hostId, 'h1');
    expect(find.text('Reinstall'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('Uninstall'), findsOneWidget);
    expect(find.text('Install'), findsNothing);
  });

  testWidgets('an older host reads "older than the server\'s" and offers '
      'Update', (tester) async {
    answer(
      (request) => request.action == SshDeployAction.check
          ? server.sshWork.boxReading(
              HostInstallState.outdated,
              installedVersion: '1.24.0',
            )
          : server.sshWork.boxReading(HostInstallState.installed),
    );
    await pump(tester);

    await press(tester, 'Check');
    expect(
      find.text(
        'Karmashala host: older than the server\'s (1.24.0 → 1.25.0), running',
      ),
      findsOneWidget,
    );

    await press(tester, 'Update');
    expect(server.sshWork.deploys.last.action, SshDeployAction.install);
    expect(
      find.text('Karmashala host: installed 1.25.0 (running)'),
      findsOneWidget,
    );
  });

  testWidgets('a newer host is said to be newer, and going back is not '
      'called Update', (tester) async {
    answer(
      (_) => server.sshWork.boxReading(
        HostInstallState.outdated,
        installedVersion: '1.26.0',
      ),
    );
    await pump(tester);

    await press(tester, 'Check');
    expect(
      find.text(
        'Karmashala host: newer than the server\'s (1.26.0; the server '
        'carries 1.25.0), running',
      ),
      findsOneWidget,
    );
    expect(find.text('Update'), findsNothing);
    expect(find.text('Install 1.25.0'), findsOneWidget);
  });

  testWidgets('Stop asks first when the host holds work, and Start brings it '
      'back', (tester) async {
    answer(
      (request) => switch (request.action) {
        SshDeployAction.stop => server.sshWork.boxReading(
          HostInstallState.installed,
          running: false,
          reason: 'Stopped. The 2 session(s) it held have ended.',
        ),
        _ => server.sshWork.boxReading(
          HostInstallState.installed,
          sessionsHeld: request.action == SshDeployAction.check ? 2 : null,
        ),
      },
    );
    await pump(tester);
    await press(tester, 'Check');

    await press(tester, 'Stop');
    expect(
      find.textContaining('The 2 sessions it holds end with it'),
      findsOneWidget,
    );
    expect(
      server.sshWork.deploys.map((d) => d.action),
      [SshDeployAction.check],
      reason: 'nothing before the answer',
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Stop'));
    await tester.pumpAndSettle();
    expect(
      find.text('Karmashala host: installed 1.25.0 (stopped)'),
      findsOneWidget,
    );
    expect(find.textContaining('have ended'), findsOneWidget);

    await press(tester, 'Start');
    expect(server.sshWork.deploys.last.action, SshDeployAction.start);
    expect(
      find.text('Karmashala host: installed 1.25.0 (running)'),
      findsOneWidget,
    );
  });

  testWidgets('Uninstall says what goes and what stays, then asks the server '
      '— and the relay row here goes with it', (tester) async {
    server.writeAsAnotherClient([
      const PreferenceChanged(
        kSshRelaysMetadataKey,
        '[{"hostId":"h1","hostName":"do-box","port":8787,'
        '"url":"ws://203.0.113.9:8787/k/0123456789abcdef0123456789abcdef",'
        '"enabled":true}]',
      ),
    ]);
    final container = await pump(tester);
    await press(tester, 'Check');

    await press(tester, 'Uninstall');
    expect(find.textContaining('~/.karmashala/bin is deleted'), findsOneWidget);
    expect(
      server.sshWork.deploys.map((d) => d.action),
      isNot(contains(SshDeployAction.remove)),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Uninstall'));
    await tester.pumpAndSettle();

    expect(find.text('Karmashala host: not installed'), findsOneWidget);
    expect(server.sshWork.deploys.last.action, SshDeployAction.remove);
    expect(container.read(sshRelaysProvider), isEmpty);
  });

  testWidgets('a server with no bundle for the box says so, with its remedy '
      'and Retry', (tester) async {
    answer(
      (_) => server.sshWork.boxReading(
        HostInstallState.cannotInstall,
        offeredVersion: null,
        deployment: HostDeployment(
          status: HostDeploymentStatus.noBinary,
          observedAt: testTime,
          reason:
              '203.0.113.9 is linux-arm64, and the Karmashala server has no '
              'host bundle for it (it looked in /srv/bundles; it has '
              'linux-x64).',
          platform: _arm,
          availableTargets: const ['linux-x64'],
        ),
      ),
    );
    await pump(tester);

    await press(tester, 'Check');

    expect(find.text('Karmashala host: can\'t install'), findsOneWidget);
    expect(find.textContaining('it looked in /srv/bundles'), findsOneWidget);
    expect(find.textContaining('linux-arm64 host bundle'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.textContaining('dart build cli'), findsNothing);
    expect(find.textContaining('Bad state'), findsNothing);
  });

  testWidgets('on a debug run the remedy carries the build command', (
    tester,
  ) async {
    answer(
      (_) => server.sshWork.boxReading(
        HostInstallState.cannotInstall,
        deployment: HostDeployment(
          status: HostDeploymentStatus.noBinary,
          observedAt: testTime,
          reason: 'No bundle.',
          platform: _arm,
        ),
      ),
    );
    await pump(tester, debugRun: true);
    await press(tester, 'Check');
    expect(find.textContaining('dart build cli'), findsOneWidget);
    expect(find.textContaining('--target-arch=arm64'), findsOneWidget);
  });

  group('a step that needs sudo', () {
    const command = 'sudo apt-get install -y tar';

    HostInstallReading missingTar(SshDeploy _) => server.sshWork.boxReading(
      HostInstallState.notInstalled,
      deployment: HostDeployment(
        status: HostDeploymentStatus.cannotInstall,
        observedAt: testTime,
        reason: '203.0.113.9 has no `tar`. Nothing was uploaded.',
        privileged: const PrivilegedCommand(
          command: command,
          does: 'Installs tar on 203.0.113.9 from its own package manager.',
          why:
              'Installing a system package changes the whole machine and '
              'needs root, so it is yours to run, in a terminal there.',
        ),
      ),
    );

    testWidgets('shows the command, what it does and why — and the app runs '
        'nothing', (tester) async {
      answer(missingTar);
      await pump(tester);
      await press(tester, 'Check');

      expect(find.text(command), findsOneWidget);
      expect(find.textContaining('Installs tar on'), findsOneWidget);
      expect(
        find.textContaining('yours to run, in a terminal there'),
        findsOneWidget,
      );
      expect(find.text('Open a terminal on do-box'), findsOneWidget);
    });

    testWidgets('"Open a terminal" types the command there and does not press '
        'Enter', (tester) async {
      answer(missingTar);
      await pump(tester);
      await press(tester, 'Check');

      await press(tester, 'Open a terminal on do-box');

      expect(terminals, [(host: 'do-box', typed: command)]);
      expect(find.textContaining('not run: press Enter there'), findsOneWidget);
    });

    testWidgets('"Check again" installs through the server', (tester) async {
      answer(missingTar);
      await pump(tester);
      await press(tester, 'Check');
      answer((_) => server.sshWork.boxReading(HostInstallState.installed));

      await press(tester, 'Check again');

      expect(server.sshWork.deploys.last.action, SshDeployAction.install);
      expect(
        find.text('Karmashala host: installed 1.25.0 (running)'),
        findsOneWidget,
      );
      expect(find.text(command), findsNothing);
    });
  });

  testWidgets('a refusal from the server is shown in its words', (
    tester,
  ) async {
    answer((_) => throw const DataRefused.notFound('no SSH host is saved as h1'));
    await pump(tester);
    await press(tester, 'Check');
    expect(find.textContaining('no SSH host is saved as h1'), findsOneWidget);
  });

  testWidgets('survives the window matrix at its wordiest', (tester) async {
    answer(
      (_) => server.sshWork.boxReading(
        HostInstallState.notInstalled,
        deployment: HostDeployment(
          status: HostDeploymentStatus.cannotInstall,
          observedAt: testTime,
          reason: 'no tar',
          privileged: const PrivilegedCommand(
            command: 'sudo apt-get install -y tar',
            does: 'Installs tar.',
            why: 'It needs root.',
          ),
        ),
      ),
    );
    await expectSurvivesWindowMatrix(
      tester,
      build: () => panel(containerFor()),
      warmUp: (tester) async {
        await tester.tap(find.text('Check'));
        await tester.pumpAndSettle();
      },
      because: 'a sentence, a remedy, a command and five buttons in one card',
    );
  });
}
