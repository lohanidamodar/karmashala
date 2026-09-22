import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/lifecycle/app_lifecycle.dart';
import 'package:karmashala/src/core/probe/probe_mode.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_hook_installation_service.dart';
import 'package:karmashala/src/features/agents/application/agent_hook_intake.dart';
import 'package:karmashala/src/features/agents/application/agent_hook_spool_drainer.dart';
import 'package:karmashala/src/features/agents/application/agent_skill_installation_service.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/remote/application/relay_prefs.dart';
import 'package:karmashala/src/features/remote/application/remote_access_controller.dart';
import 'package:karmashala/src/features/remote/application/remote_host_service.dart';
import 'package:karmashala/src/features/remote/relay_local/local_relay_providers.dart';
import 'package:karmashala/src/features/remote/relay_local/local_relay_service.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/system/system_integration_service.dart';
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:karmashala_notifications/toasts.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/devices.dart';
import 'package:path/path.dart' as p;

import '../../features/remote/fake_bindings.dart';
import '../../features/system/fake_native_adapters.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/temp_directory.dart';

/// Every store the locator would have found, pointed at a temporary home.
class _StubLocator implements CliStoreLocator {
  _StubLocator(this.stores);

  final List<CliStore> stores;
  final visited = <String>[];

  @override
  Future<List<CliStore>> locate(List<ExecutionEnvironment> environments) async {
    visited.addAll(environments.map((e) => e.id));
    return stores;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Stands in for the hook service where the question is whether it is *called*.
class _RecordingHookService extends AgentHookInstallationService {
  _RecordingHookService(super.ref);

  final calls = <String>[];

  @override
  Future<List<AgentHookInstallation>> installAll(
    AgentHookEndpoint endpoint,
  ) async {
    calls.add('installAll');
    return const [];
  }

  @override
  Future<List<AgentHookInstallation>> retireEndpoints() async {
    calls.add('retireEndpoints');
    return const [];
  }

  @override
  Future<List<AgentHookInstallation>> uninstallAll() async {
    calls.add('uninstallAll');
    return const [];
  }
}

final _refProvider = Provider<Ref>((ref) => ref);

/// **A probe performs no global side effect.** Each case drives the real seam
/// against a temporary "agent store", and each has a non-probe twin proving the
/// same fixture *can* observe the write — so a pass is not an empty fixture.
void main() {
  late AppDatabase db;
  late Directory home;

  setUp(() {
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    home = Directory.systemTemp.createTempSync('karmashala_probe_fx_');
  });
  tearDown(() {
    db.close();
    removeTempDirectory(home);
  });

  String localEnvironmentId() => ExecutionEnvironmentDao(
    db,
  ).getAll().firstWhere((e) => isLocalHost(e.kind)).id;

  String claudeStore() => p.join(home.path, '.claude');
  File hookConfig() => File(p.join(claudeStore(), 'settings.json'));
  File endpointFile() =>
      File(p.join(claudeStore(), '$agentHookMarker.endpoint'));

  _StubLocator localStore() => _StubLocator([
    CliStore(
      environmentId: localEnvironmentId(),
      homesByAgentId: {'claudeCode': claudeStore()},
    ),
  ]);

  ProviderContainer containerWith({
    required bool probe,
    CliStoreLocator? locator,
    List<Override> extra = const [],
  }) {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        probeModeProvider.overrideWithValue(
          probe ? ProbeMode.on : ProbeMode.off,
        ),
        if (locator != null) cliStoreLocatorProvider.overrideWithValue(locator),
        ...extra,
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  const endpoint = AgentHookEndpoint(port: 4242, token: 'tok');

  group('agent hooks in the agent stores', () {
    setUp(() => Directory(claudeStore()).createSync(recursive: true));

    test('the fixture sees an ordinary install write both files', () async {
      final container = containerWith(probe: false, locator: localStore());

      await container
          .read(agentHookInstallationServiceProvider)
          .installAll(endpoint);

      expect(hookConfig().existsSync(), isTrue);
      expect(endpointFile().existsSync(), isTrue);
    });

    test('a probe writes no hook and no endpoint file', () async {
      final locator = localStore();
      final container = containerWith(probe: true, locator: locator);

      final results = await container
          .read(agentHookInstallationServiceProvider)
          .installAll(endpoint);

      expect(results, isEmpty);
      expect(hookConfig().existsSync(), isFalse);
      expect(endpointFile().existsSync(), isFalse);
      expect(
        locator.visited,
        isEmpty,
        reason: 'not even the store homes are looked up',
      );
    });

    test('a probe retires and uninstalls nothing the real app wrote', () async {
      // The real app's install, made by an ordinary container first.
      await containerWith(
        probe: false,
        locator: localStore(),
      ).read(agentHookInstallationServiceProvider).installAll(endpoint);
      final config = hookConfig().readAsStringSync();
      final published = endpointFile().readAsStringSync();

      final service = containerWith(
        probe: true,
        locator: localStore(),
      ).read(agentHookInstallationServiceProvider);
      await service.retireEndpoints();
      await service.uninstallAll();

      expect(endpointFile().readAsStringSync(), published);
      expect(hookConfig().readAsStringSync(), config);
    });
  });

  group('agent skills in the agent stores', () {
    setUp(() => Directory(claudeStore()).createSync(recursive: true));

    Directory skillsRoot() => Directory(p.join(claudeStore(), 'skills'));

    test('the fixture sees an ordinary sweep write skills', () async {
      final container = containerWith(probe: false, locator: localStore());

      await AgentSkillInstallationService(container.read(_refProvider)).sweep();

      expect(skillsRoot().existsSync(), isTrue);
    });

    test('a probe installs and removes no skill', () async {
      final container = containerWith(probe: true, locator: localStore());
      final service = AgentSkillInstallationService(
        container.read(_refProvider),
      );

      await service.sweep();
      await service.sweepRemoval();

      expect(skillsRoot().existsSync(), isFalse);
    });
  });

  group('the spool drainer', () {
    late Directory spool;

    setUp(() {
      spool = Directory(p.join(home.path, 'spool'))..createSync();
      File(
        p.join(spool.path, '1-0.json'),
      ).writeAsStringSync('agent=claudeCode\nevent=Stop\n\n{"session_id":"s"}');
    });

    AgentHookSpoolSource source() => AgentHookSpoolSource(
      environmentId: 'local',
      directory: spool,
      wslDistribution: null,
    );

    test('the fixture sees an ordinary drainer take the payload', () async {
      final seen = <AgentHookSpoolEvent>[];
      final drainer = AgentHookSpoolDrainer(onEvent: seen.add);
      addTearDown(drainer.dispose);

      drainer.watch([source()]);
      await drainer.drainOnce();

      expect(seen, hasLength(1));
      expect(spool.listSync(), isEmpty);
    });

    test("a probe's drainer polls nothing and takes nothing", () async {
      final container = containerWith(probe: true);
      final drainer = container.read(agentHookSpoolDrainerProvider);

      drainer.watch([source()]);
      await drainer.drainOnce();

      expect(drainer.enabled, isFalse);
      expect(drainer.sources, isEmpty);
      expect(
        spool.listSync(),
        hasLength(1),
        reason: 'the payload is still there',
      );
    });
  });

  group('the lifecycle', () {
    ProviderContainer withRecorder(
      bool probe,
      List<_RecordingHookService> out,
    ) => containerWith(
      probe: probe,
      extra: [
        agentHookInstallationServiceProvider.overrideWith((ref) {
          final service = _RecordingHookService(ref);
          out.add(service);
          return service;
        }),
      ],
    );

    test('an ordinary quit retires the endpoints', () async {
      final made = <_RecordingHookService>[];
      final lifecycle = AppLifecycle(withRecorder(false, made));

      await lifecycle.shutdown();

      expect(made.single.calls, ['retireEndpoints']);
    });

    test('a probe quitting retires nothing', () async {
      final made = <_RecordingHookService>[];
      final lifecycle = AppLifecycle(withRecorder(true, made));

      await lifecycle.shutdown();

      expect(made.expand((s) => s.calls), isEmpty);
    });

    test('a probe launching installs no hooks and no skills', () async {
      final made = <_RecordingHookService>[];
      final container = withRecorder(true, made);
      final lifecycle = AppLifecycle(container);
      final server = LauncherControlServer(container);

      lifecycle.installAgentHooks(server);
      lifecycle.installAgentSkills();
      await pumpEventQueue();

      expect(made.expand((s) => s.calls), isEmpty);
      expect(
        server.onWslInterfaceBound,
        isNull,
        reason: 'no re-sweep is armed for when WSL appears either',
      );
    });
  });

  group('remote access and the local relay', () {
    late LocalRelayService relay;
    late int factoryCalls;

    ProviderContainer remoteContainer(bool probe) {
      relay = LocalRelayService(
        bindAddress: '127.0.0.1',
        interfaces: () async => [(name: 'lo', ip: '127.0.0.1')],
      );
      addTearDown(relay.stop);
      factoryCalls = 0;
      final fake = FakeRemoteBindings();
      return containerWith(
        probe: probe,
        extra: [
          localRelayServiceProvider.overrideWithValue(relay),
          remoteAccessControllerProvider.overrideWith(
            (ref) => RemoteAccessController(
              ref,
              serviceFactory: (relayUri) {
                factoryCalls++;
                return RemoteHostService(
                  devices: PairedDeviceDao(db),
                  hostId: DeviceId.parse('11111111222222223333333344444444'),
                  bindings: fake.bindings,
                  relay: relayUri,
                  lanPort: 0,
                  advertise: false,
                  transcriptPollInterval: Duration.zero,
                );
              },
            ),
          ),
        ],
      );
    }

    Future<RemoteAccessController> enableEverything(
      ProviderContainer container,
    ) async {
      final controller = container.read(remoteAccessControllerProvider);
      addTearDown(controller.shutdown);
      container.read(settingsControllerProvider.notifier)
        ..setRemoteAccessEnabled(true)
        ..setLocalRelayPort(0);
      container.read(relayPrefsProvider.notifier).setLocalEnabled(true);
      await controller.sync();
      return controller;
    }

    test('the fixture sees an ordinary instance bind the relay', () async {
      final controller = await enableEverything(remoteContainer(false));

      expect(relay.isRunning, isTrue);
      expect(controller.isRunning, isTrue);
    });

    test('a probe binds no relay, starts no host and cannot pair', () async {
      final controller = await enableEverything(remoteContainer(true));

      expect(relay.isRunning, isFalse);
      expect(controller.isRunning, isFalse);
      expect(factoryCalls, 0, reason: 'no LAN listener, beacon or relay dial');
      expect(
        () => controller.beginPairing(capabilities: CapabilitySet.all),
        throwsStateError,
      );
    });
  });

  group('the control server', () {
    Future<int> freePort() async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      return port;
    }

    test('a probe does not take the preferred port', () async {
      final wanted = await freePort();
      final container = containerWith(probe: true);
      final server = LauncherControlServer(container);
      await server.start(
        bridgeFilePath: p.join(home.path, 'mcp_bridge.json'),
        socketDirectory: p.join(home.path, 'ipc'),
        preferredPort: wanted,
        hostCanHaveWsl: false,
      );
      addTearDown(server.stop);

      expect(server.hookEndpoint!.port, isNot(wanted));
      expect(server.hookEndpoint!.port, greaterThan(0));
    });
  });

  group('OS integration', () {
    test(
      'a probe writes no launch-at-login entry and takes no hotkey',
      () async {
        final natives = FakeNatives();
        final container = containerWith(probe: true);
        final service = SystemIntegrationService(
          container,
          adapters: natives.adapters,
          registerOsQuit: (_) {},
          endProcess: () {},
        );

        await service.init();
        // A user flipping both in the probe's settings, and a focus retry.
        container.read(settingsControllerProvider.notifier)
          ..setAutoStart(true)
          ..setLauncherHotkeyEnabled(true);
        await pumpEventQueue();
        await service.retryOutstanding();

        expect(natives.autoStart.calls, isEmpty);
        expect(natives.hotkey.calls, isEmpty);
        expect(natives.tray.tooltip, 'Karmashala PROBE');
      },
    );

    test('an ordinary instance still registers both', () async {
      final natives = FakeNatives();
      final container = containerWith(probe: false);
      final service = SystemIntegrationService(
        container,
        adapters: natives.adapters,
        registerOsQuit: (_) {},
        endProcess: () {},
      );

      await service.init();

      expect(natives.autoStart.calls, contains('setup'));
      expect(natives.hotkey.calls, contains('register'));
      expect(natives.tray.tooltip, 'Karmashala');
    });

    test('a probe shows no OS toast', () {
      final container = containerWith(probe: true);

      expect(
        container.read(notificationPresenterProvider),
        isA<NoopNotificationPresenter>(),
      );
    });
  });
}
