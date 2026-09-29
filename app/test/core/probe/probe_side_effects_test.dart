import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/lifecycle/app_lifecycle.dart';
import 'package:karmashala/src/core/probe/probe_mode.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_hook_installation_service.dart';
import 'package:karmashala/src/features/agents/application/agent_skill_installation_service.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/remote/application/host_companion_link.dart';
import 'package:karmashala/src/features/remote/application/host_companion_providers.dart';
import 'package:karmashala/src/features/remote/application/remote_access_controller.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/system/system_integration_service.dart';
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:karmashala_notifications/toasts.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:path/path.dart' as p;
import '../../support/memory_server_config.dart';

import '../../features/system/fake_native_adapters.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/temp_directory.dart';
import '../../support/test_machine.dart';
import '../../support/fake_data_server.dart';
import '../../support/fake_host_lifecycle.dart';

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
  late TestMachine db;
  late FakeDataServer server;
  late Override data;
  late Directory home;

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(
      localHostEnvironment(FixedClock(testTime).nowUtc()),
    );
    data = await server.override();
    home = Directory.systemTemp.createTempSync('karmashala_probe_fx_');
  });
  tearDown(() {
    removeTempDirectory(home);
  });

  String localEnvironmentId() => db.server.environmentRows
      .getAll()
      .firstWhere((e) => isLocalHost(e.kind))
      .id;

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
        data,
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

      lifecycle.installAgentHooks();
      lifecycle.installAgentSkills();
      await pumpEventQueue();

      expect(made.expand((s) => s.calls), isEmpty);
    });
  });

  group('remote access', () {
    late FakeHostLifecycle host;

    Future<ProviderContainer> remoteContainer(bool probe) async {
      host = FakeHostLifecycle();
      final link = HostCompanionLink(deviceById: (_) async => null);
      final container = containerWith(
        probe: probe,
        extra: [
          companionAtHostProvider.overrideWithValue(true),
          hostCompanionLinkProvider.overrideWithValue(link),
          remoteAccessControllerProvider.overrideWith(
            RemoteAccessController.new,
          ),
        ],
      );
      link.attached((await host.open())!);
      return container;
    }

    // The LAN relay is the server's since protocol 29: no instance of the
    // app binds a port for phones, probe or not. What is left to keep a
    // probe from is pairing a phone to the real server.
    test('a probe cannot pair', () async {
      final container = await remoteContainer(true);
      final controller = container.read(remoteAccessControllerProvider);
      setRemoteAccessNow(container, enabled: true);
      await controller.sync();

      expect(
        () => controller.beginPairing(capabilities: CapabilitySet.all),
        throwsStateError,
      );
      expect(host.pairings, isEmpty);
      expect(host.serverCalls, isEmpty, reason: 'nothing written to it');
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
