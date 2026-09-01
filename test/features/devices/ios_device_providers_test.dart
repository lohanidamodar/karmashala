import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/devices/application/ios_device_providers.dart';
import 'package:karmashala/src/features/devices/data/idb_service.dart';
import 'package:karmashala/src/features/devices/domain/ios_simulator.dart';

import '../../support/fake_command_runner.dart';

IosSimulator _sim(String udid, String name, SimulatorState state) =>
    IosSimulator(
      udid: udid,
      name: name,
      state: state,
      runtime: 'com.apple.CoreSimulator.SimRuntime.iOS-26-4',
      deviceTypeIdentifier: 'com.apple.CoreSimulator.SimDeviceType.iPhone-17',
      isAvailable: true,
    );

ProviderContainer _container({
  bool macOS = true,
  IdbInstallation? idb,
  List<IosSimulator> simulators = const [],
}) {
  final container = ProviderContainer(
    overrides: [
      commandRunnerFactoryProvider.overrideWithValue(
        FakeCommandRunnerFactory(),
      ),
      hostCanRunSimulatorsProvider.overrideWithValue(macOS),
      idbInstallationProvider.overrideWith((ref) async => idb),
      iosSimulatorsProvider.overrideWith((ref) async => simulators),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('a host that cannot have simulators', () {
    test('offers nothing, and says why, without spawning anything', () async {
      // The same mistake `wsl.exe` was making on a Mac: a fact about the OS is
      // not something to rediscover by spawning a process every refresh.
      final runner = FakeCommandRunner();
      final container = ProviderContainer(
        overrides: [
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(fallback: runner),
          ),
          hostCanRunSimulatorsProvider.overrideWithValue(false),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(simctlServiceProvider), isNull);
      expect(await container.read(iosSimulatorsProvider.future), isEmpty);
      expect(await container.read(idbInstallationProvider.future), isNull);

      final support = container.read(simulatorSupportProvider);
      expect(support.capabilities, isEmpty);
      expect(support.missingReason, contains('macOS'));
      expect(runner.requests, isEmpty, reason: 'nothing was spawned');
    });
  });

  group('capabilities', () {
    test('simctl alone manages but cannot interact, and names the fix', () async {
      final container = _container();
      await container.read(idbInstallationProvider.future);

      final support = container.read(simulatorSupportProvider);

      expect(support.has(SimulatorCapability.manage), isTrue);
      expect(support.has(SimulatorCapability.interact), isFalse);
      // "Unsupported" would send someone looking for a bug in the app. simctl
      // genuinely has no touch injection and no way to read the screen.
      expect(support.missingReason, contains('idb'));
      expect(support.missingReason, contains('brew'));
    });

    test('with idb, everything is available and nothing is missing', () async {
      final container = _container(
        idb: const IdbInstallation(executable: '/opt/homebrew/bin/idb'),
      );
      await container.read(idbInstallationProvider.future);

      final support = container.read(simulatorSupportProvider);

      expect(support.has(SimulatorCapability.manage), isTrue);
      expect(support.has(SimulatorCapability.interact), isTrue);
      expect(support.missingReason, isNull);
    });
  });

  group('selection', () {
    test('one booted simulator needs no choosing', () async {
      // On a machine with a hundred of them, a user who booted exactly one has
      // already said which they mean.
      final container = _container(
        simulators: [
          _sim('a', 'iPhone 17', SimulatorState.shutdown),
          _sim('b', 'iPhone 16', SimulatorState.booted),
          _sim('c', 'iPad', SimulatorState.shutdown),
        ],
      );
      await container.read(iosSimulatorsProvider.future);

      expect(container.read(selectedSimulatorProvider)?.udid, 'b');
    });

    test('several booted, or none, is the user\'s choice to make', () async {
      final several = _container(
        simulators: [
          _sim('a', 'iPhone 17', SimulatorState.booted),
          _sim('b', 'iPhone 16', SimulatorState.booted),
        ],
      );
      await several.read(iosSimulatorsProvider.future);
      expect(several.read(selectedSimulatorProvider), isNull);

      final none = _container(
        simulators: [_sim('a', 'iPhone 17', SimulatorState.shutdown)],
      );
      await none.read(iosSimulatorsProvider.future);
      expect(none.read(selectedSimulatorProvider), isNull);
    });

    test('an explicit pick wins over the booted one', () async {
      final container = _container(
        simulators: [
          _sim('a', 'iPhone 17', SimulatorState.shutdown),
          _sim('b', 'iPhone 16', SimulatorState.booted),
        ],
      );
      await container.read(iosSimulatorsProvider.future);

      container.read(selectedSimulatorUdidProvider.notifier).select('a');

      expect(container.read(selectedSimulatorProvider)?.udid, 'a');
    });

    test('a pick that no longer exists falls back rather than sticking', () async {
      // A simulator can be deleted from Xcode while the pane is open.
      final container = _container(
        simulators: [_sim('b', 'iPhone 16', SimulatorState.booted)],
      );
      await container.read(iosSimulatorsProvider.future);

      container.read(selectedSimulatorUdidProvider.notifier).select('gone');

      expect(container.read(selectedSimulatorProvider)?.udid, 'b');
    });
  });
}
