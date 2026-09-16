import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/editor/application/code_editor_providers.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/projects/presentation/edit_project_dialog.dart';
import 'package:karmashala/src/features/projects/presentation/new_project_dialog.dart';
import 'package:karmashala/src/features/remote/application/remote_access_controller.dart';
import 'package:karmashala/src/features/remote/pairing/pairing_relay_endpoints.dart';
import 'package:karmashala/src/features/remote/relay_local/local_relay_providers.dart';
import 'package:karmashala/src/features/remote/relay_local/local_relay_service.dart';
import 'package:karmashala/src/features/remote/presentation/pairing_dialog.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/workspaces/data/workspace_dao.dart';
import 'package:karmashala/src/features/workspaces/domain/workspace.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/presentation/external_app_section.dart';
import 'package:karmashala/src/features/settings/presentation/settings_nav.dart';
import 'package:karmashala/src/features/settings/presentation/settings_screen.dart';
import 'package:karmashala/src/features/ssh/application/host_session_providers.dart';
import 'package:karmashala/src/features/ssh/presentation/host_sessions_dialog.dart';
import 'package:karmashala/src/features/ssh/presentation/pair_phone_dialog.dart';
import 'package:karmashala/src/features/ssh/application/host_sessions.dart';
import 'package:karmashala/src/features/ssh/data/ssh_host_dao.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_theme_controller.dart';
import 'package:karmashala_host/protocol.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala_ssh/host.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/devices.dart';

import '../support/fake_command_runner.dart';
import '../support/fakes.dart';
import '../support/fixtures.dart';
import '../support/window_matrix.dart';

/// The settings surfaces — pages, their cards and the dialogs they open — with
/// user data of realistic length: host names, distro names, project names and
/// paths are whatever the user typed, and the shared matrix files seed short
/// ones.

/// Nothing here may shell out.
// ignore: strict_top_level_inference
noProcessOverrides() => [
  commandRunnerFactoryProvider.overrideWithValue(
    FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
  ),
  hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
];

Widget app(ProviderContainer container, Widget home) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: home, debugShowCheckedModeBanner: false),
    );

/// The narrowest window that still draws settings in two columns: it failed
/// where 720x560, which stacks, did not.
const narrowestTwoColumn = WindowCell('760x560', Size(760, 560));
const narrowestTwoColumnLargeText = WindowCell(
  '760x560 @ 1.3x',
  Size(760, 560),
  textScale: 1.3,
);

const settingsMatrix = [
  ...windowMatrix,
  desktopLargeText,
  narrowestTwoColumn,
  narrowestTwoColumnLargeText,
];

void main() {
  testWidgets('Environments section with a long SSH host name', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ExecutionEnvironmentDao(db)
      ..upsert(windowsEnv())
      ..upsert(
        wslEnv(
          id: 'wsl:Ubuntu-22.04-with-a-long-name',
          distro: 'Ubuntu-22.04-with-a-long-name',
        ),
      );
    SshHostDao(db).upsert(
      SshHost(
        id: 'h1',
        name: 'build-box-in-the-basement-with-a-long-name',
        host: 'build-server-01.internal.corp.example.popupbits.com',
        port: 2222,
        username: 'dlohani-service-account',
        authMethod: SshAuthMethod.password,
        createdAt: testTime,
      ),
    );
    // A project on the host draws the count pill beside the name.
    ExecutionEnvironmentDao(
      db,
    ).upsert(sshEnvFixture(name: 'build-box-in-the-basement-with-a-long-name'));
    ProjectDao(
      db,
    ).insert(project(environmentId: 'ssh:h1', path: '/home/dlohani/src/demo'));
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        ...noProcessOverrides(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator()),
        discoveredTerminalThemesProvider.overrideWithValue(const []),
      ],
    );
    addTearDown(container.dispose);

    await expectSurvivesWindowMatrix(
      tester,
      build: () => app(
        container,
        const SettingsScreen(initialSection: SettingsSectionId.environments),
      ),
      matrix: settingsMatrix,
      because:
          'host names, WSL distro names and paths are user data of any length',
    );
  });

  group('project dialogs with long names', () {
    const longDistro = 'Ubuntu-22.04-LTS-with-a-long-distribution-name';
    const longContext =
        'Client work for the long-running migration engagement, phase two';
    const longCheckout =
        'karmashala-app-checkout-with-an-unreasonably-long-folder-name';

    AppDatabase seeded() {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      ExecutionEnvironmentDao(db)
        ..upsert(windowsEnv())
        ..upsert(wslEnv(id: 'wsl:$longDistro', distro: longDistro));
      WorkspaceDao(
        db,
      ).insert(Workspace(id: 'w1', name: longContext, createdAt: testTime));
      ProjectDao(db).insert(
        project(
          environmentId: 'wsl:$longDistro',
          path: '/home/dlohani/src/demo',
          workspaceId: 'w1',
        ),
      );
      RepositoryDao(db).insert(
        repository(
          name: longCheckout,
          environmentId: 'wsl:$longDistro',
          path: '/home/dlohani/src/demo/app',
        ),
      );
      ProjectDao(db).setDefaultRepository('p1', 'r1');
      return db;
    }

    ProviderContainer containerFor(AppDatabase db) {
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          ...noProcessOverrides(),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          idGeneratorProvider.overrideWithValue(SequentialIdGenerator()),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    testWidgets('EditProjectDialog', (tester) async {
      final db = seeded();
      final container = containerFor(db);
      final edited = ProjectDao(db).getById('p1')!;
      await expectSurvivesWindowMatrix(
        tester,
        build: () => app(container, EditProjectDialog(project: edited)),
        matrix: settingsMatrix,
        because:
            'the environment, context and default checkout dropdowns show '
            'names the user chose',
      );
    });

    testWidgets('NewProjectDialog', (tester) async {
      final container = containerFor(seeded());
      await expectSurvivesWindowMatrix(
        tester,
        build: () => app(
          container,
          const NewProjectDialog(initialEnvironmentId: 'wsl:$longDistro'),
        ),
        warmUp: (tester) async {
          // Pick the long context, then return to the top of the dialog.
          await tester.ensureVisible(find.text('None'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('None'));
          await tester.pumpAndSettle();
          await tester.tap(find.text(longContext).last);
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('New project'));
        },
        matrix: settingsMatrix,
        because:
            'the environment and context dropdowns show names the user chose',
      );
    });
  });

  group('PairPhoneDialog', () {
    final host = SshHost(
      id: 'h1',
      name: 'build-box-in-the-basement-with-a-long-name',
      host: 'build-server-01.internal.corp.example.popupbits.com',
      port: 22,
      username: 'dlohani',
      authMethod: SshAuthMethod.password,
      createdAt: testTime,
    );

    Widget opener(ProviderContainer container) => app(
      container,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => PairPhoneDialog.show(context, host: host),
            child: const Text('Open'),
          ),
        ),
      ),
    );

    Future<void> open(WidgetTester tester) async {
      await tester.tap(find.text('Open'));
    }

    testWidgets('while it asks the host for a code', (tester) async {
      final container = ProviderContainer(
        overrides: [
          ...noProcessOverrides(),
          sshCompanionSetupProvider.overrideWith(
            (ref, host) => Completer<Never>().future,
          ),
        ],
      );
      addTearDown(container.dispose);
      await expectSurvivesWindowMatrix(
        tester,
        build: () => opener(container),
        warmUp: open,
        matrix: settingsMatrix,
        because: 'the busy line is a sentence beside a spinner',
      );
    });

    testWidgets('with an address and a code to copy', (tester) async {
      final container = ProviderContainer(
        overrides: [
          ...noProcessOverrides(),
          sshCompanionSetupProvider.overrideWith(
            (ref, host) async => _InvitingSetup(host),
          ),
        ],
      );
      addTearDown(container.dispose);
      await expectSurvivesWindowMatrix(
        tester,
        build: () => opener(container),
        warmUp: open,
        matrix: settingsMatrix,
        because:
            'the address is the host name the user typed, and two notes sit '
            'under it',
      );
    });
  });

  group('dialogs whose content scrolls keep one tab ring', () {
    testWidgets('PairingDialog with two relays to choose between', (
      tester,
    ) async {
      await expectSurvivesWindowMatrix(
        tester,
        build: () => ProviderScope(
          overrides: [
            remoteAccessControllerProvider.overrideWith(_PairingAccess.new),
            pairingRelayEndpointsProvider.overrideWith(
              (ref) => [
                PairingRelayEndpoint(
                  label: 'Internet',
                  url: Uri.parse('wss://relay.popupbits.com'),
                  kind: PairingRelayKind.internet,
                ),
                PairingRelayEndpoint(
                  label: 'Local network',
                  url: Uri.parse('ws://192.168.1.20:7011'),
                  kind: PairingRelayKind.local,
                ),
              ],
            ),
          ],
          child: const MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(body: PairingDialog()),
          ),
        ),
        matrix: settingsMatrix,
        because:
            'nine capability chips, two relay tabs and a QR scroll inside '
            'the dialog, and Tab must visit each stop once',
      );
    });

    testWidgets('HostSessionsDialog with enough sessions to scroll', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          ...noProcessOverrides(),
          hostSessionsServiceProvider.overrideWithValue(_ListingSessions(12)),
        ],
      );
      addTearDown(container.dispose);
      await expectSurvivesWindowMatrix(
        tester,
        build: () => app(
          container,
          HostSessionsDialog(
            host: SshHost(
              id: 'h1',
              name: 'build-box',
              host: 'build.example.internal',
              port: 22,
              username: 'dlohani',
              authMethod: SshAuthMethod.password,
              createdAt: testTime,
            ),
          ),
        ),
        matrix: settingsMatrix,
        because:
            'the session list scrolls under the dialog actions, and Tab must '
            'visit each row once before it reaches them',
      );
    });
  });

  testWidgets('Remote access section with a long device name', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    PairedDeviceDao(db).insert(
      PairedDevice(
        id: 'a' * 32,
        name: "Damodar's Pixel 9 Pro XL (work profile, second SIM, travel)",
        deviceKey: Uint8List(32),
        capabilities: CapabilitySet.all,
        generation: 1,
        createdAt: testTime,
        lastSeenAt: testTime,
      ),
    );
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        ...noProcessOverrides(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        discoveredTerminalThemesProvider.overrideWithValue(const []),
        localRelayStatusProvider.overrideWithValue(
          const LocalRelayStatus.stopped(),
        ),
        remoteAccessControllerProvider.overrideWith(_PairingAccess.new),
      ],
    );
    addTearDown(container.dispose);
    container
        .read(settingsControllerProvider.notifier)
        .setRemoteAccessEnabled(true);

    await expectSurvivesWindowMatrix(
      tester,
      build: () => app(
        container,
        const SettingsScreen(initialSection: SettingsSectionId.remote),
      ),
      matrix: settingsMatrix,
      because:
          'a phone names itself at pairing, and the header row puts a label '
          'beside a button in the narrow two-column layout',
    );
  });

  testWidgets('Tools section with a custom terminal and editor', (
    tester,
  ) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        ...noProcessOverrides(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        discoveredTerminalThemesProvider.overrideWithValue(const []),
        availableSystemTerminalsProvider.overrideWith((ref) async => const []),
        availableCodeEditorsProvider.overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    container.read(settingsControllerProvider.notifier)
      ..setCustomTerminalPath(
        '/Applications/Utilities/Terminal Emulators/WezTerm Nightly.app',
      )
      ..setCustomEditorPath('/Applications/Visual Studio Code - Insiders.app');

    await expectSurvivesWindowMatrix(
      tester,
      build: () => app(
        container,
        const SettingsScreen(initialSection: SettingsSectionId.tools),
      ),
      matrix: settingsMatrix,
      because:
          'a custom path row puts a field and two buttons on one line, which '
          'the narrow two-column layout and bigger text cannot hold',
    );

    // The two sections on their own at a phone's width, where a field and two
    // buttons cannot share a line at all. (The rest of the Tools page is not
    // theirs to answer for: `ProjectKindsSection` overflows there too.)
    await expectSurvivesWindowMatrix(
      tester,
      build: () => app(
        container,
        const Scaffold(
          body: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ExternalAppSection(kind: ExternalAppKind.terminal),
                ExternalAppSection(kind: ExternalAppKind.editor),
              ],
            ),
          ),
        ),
      ),
      matrix: const [
        WindowCell('390x844 (phone width)', Size(390, 844)),
        WindowCell('390x844 @ 1.3x', Size(390, 844), textScale: 1.3),
      ],
      because: 'settings also draw in a single narrow column',
    );
  });
}

/// A companion setup that answers at once with a long address and an open
/// window, so the dialog's loaded state can be measured without a host.
class _InvitingSetup implements SshCompanionSetup {
  _InvitingSetup(this.host);

  @override
  final SshHost host;

  @override
  Future<({CompanionEndpoint endpoint, PairingWindow window})> invite({
    required int capabilities,
    String relay = '',
  }) async => (
    endpoint: CompanionEndpoint(
      address: host.host,
      port: 7422,
      hostName: host.name,
      reachable: false,
      reason:
          'Nothing answered on port 7422 from this desktop. Open it in the '
          "host's firewall, or pair from a network that can reach it.",
    ),
    window: PairingWindow(
      status: PairingRequestStatus.open,
      observedAt: testTime,
      reason: 'Open.',
      code: 'K7QM-3X2W-9PLA',
      expiresAt: testTime.add(const Duration(minutes: 10)),
    ),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Answers `beginPairing` with a real code, and opens nothing.
class _PairingAccess extends RemoteAccessController {
  _PairingAccess(super.ref);

  HostPairingSession? _last;

  @override
  Future<HostPairingSession> beginPairing({
    required CapabilitySet capabilities,
    Uri? relay,
    bool relayIsLocal = false,
  }) async {
    final session = HostPairingSession(
      payload: await PairingPayload.generateWithCode(
        relay: relay ?? Uri.parse('wss://relay.example.com'),
        hostId: DeviceId.parse('11111111222222223333333344444444'),
        capabilities: capabilities,
      ),
      hostName: 'Desk',
      persist: (_) async {},
    );
    return _last = session;
  }

  @override
  Future<void> sync() async {}

  @override
  Future<void> cancelPairing() async {
    await _last?.close();
    _last = null;
  }
}

/// A host holding [count] running sessions: every other one a bare shell that
/// can be reattached, the rest agent sessions that cannot.
class _ListingSessions implements HostSessionsService {
  _ListingSessions(this.count);

  final int count;

  @override
  Future<List<SessionSummary>> list(SshHost host) async => [
    for (var i = 0; i < count; i++)
      SessionSummary(
        id: i.isEven ? 'karmashala_${host.id}_pane-$i' : 'agent-$i',
        argv: ['/bin/zsh', '-l', '--session', '$i'],
        workingDirectory: '/home/dlohani/src/project-$i',
        pid: 1000 + i,
        columns: 120,
        rows: 40,
        startedAt: testTime,
        observedAt: testTime,
        totalBytes: 4096 * i,
        firstAvailableOffset: 0,
        lifecycle: const SessionRunning(),
        writeHolder: null,
      ),
  ];

  @override
  Future<void> end(SshHost host, String sessionId) async {}
}
