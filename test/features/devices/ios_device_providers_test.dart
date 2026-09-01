import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/devices/application/ios_device_providers.dart';
import 'package:karmashala/src/features/devices/data/simctl_service.dart';
import 'package:karmashala/src/features/devices/data/simulator_slimming_service.dart';
import 'package:karmashala/src/features/devices/data/wda_backend.dart';
import 'package:karmashala/src/features/devices/domain/simulator_slimming.dart';
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
  bool backend = false,
  List<IosSimulator> simulators = const [],
}) {
  final container = ProviderContainer(
    overrides: [
      commandRunnerFactoryProvider.overrideWithValue(
        FakeCommandRunnerFactory(),
      ),
      hostCanRunSimulatorsProvider.overrideWithValue(macOS),
      simulatorBackendProvider.overrideWithValue(
        backend ? _StubBackend() : null,
      ),
      iosSimulatorsProvider.overrideWith((ref) async => simulators),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

class _StubBackend implements WdaBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('the capability tests never call the backend');
}

void main() {
  group('slimming on start', _slimmingTests);

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
      expect(container.read(simulatorBackendProvider), isNull);

      final support = container.read(simulatorSupportProvider);
      expect(support.capabilities, isEmpty);
      expect(support.missingReason, contains('macOS'));
      expect(runner.requests, isEmpty, reason: 'nothing was spawned');
    });
  });

  group('capabilities', () {
    test('simctl alone manages but cannot interact, and says so', () async {
      final container = _container();

      final support = container.read(simulatorSupportProvider);

      expect(support.has(SimulatorCapability.manage), isTrue);
      expect(support.has(SimulatorCapability.interact), isFalse);
      // "Unsupported" would send someone looking for a bug in the app. simctl
      // genuinely has no touch injection and no way to read the screen.
      // Not an install instruction: WebDriverAgent ships with this app, so
      // its absence is a build problem rather than a setup step for a user.
      expect(support.missingReason, contains('WebDriverAgent'));
    });

    test('with a backend, everything is available', () async {
      final container = _container(backend: true);

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

/// Records what it was asked to slim, and can be told to fail.
class _RecordingSlimming implements SimulatorSlimmingService {
  _RecordingSlimming({this.throws = false});

  final bool throws;
  final List<({String udid, Set<SlimmingCategory> except, bool boot})> calls =
      [];

  @override
  Future<void> slim(
    String udid, {
    Set<SlimmingCategory> except = const {},
    Set<String> keep = const {},
    bool boot = true,
  }) async {
    calls.add((udid: udid, except: except, boot: boot));
    if (throws) throw StateError('the plist would not open');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('only slim() is used on the boot path');
}

/// Records the boots, so a test can tell "slimmed then booted" from "booted".
class _RecordingSimctl implements SimctlService {
  final List<String> booted = [];

  @override
  Future<void> bootAndWait(String udid, {Duration? timeout}) async =>
      booted.add(udid);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('only bootAndWait is used on this path');
}

void _slimmingTests() {
  ProviderContainer containerWith({
    required _RecordingSlimming slimming,
    required _RecordingSimctl simctl,
    bool enabled = true,
    List<String> kept = kDefaultSlimmingKept,
  }) {
    final container = ProviderContainer(
      overrides: [
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(),
        ),
        hostCanRunSimulatorsProvider.overrideWithValue(true),
        iosSimulatorsProvider.overrideWith((ref) async => const []),
        simctlServiceProvider.overrideWithValue(simctl),
        simulatorSlimmingServiceProvider.overrideWithValue(slimming),
        slimmingOnStartProvider.overrideWithValue(enabled),
        slimmingKeptCategoriesProvider.overrideWithValue({
          for (final id in kept) ?SlimmingCategory.byId(id),
        }),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('starting a simulator slims it first, then boots it', () async {
    final slimming = _RecordingSlimming();
    final simctl = _RecordingSimctl();
    final container = containerWith(slimming: slimming, simctl: simctl);

    await container.read(simulatorTransitionsProvider.notifier).boot('UDID');

    expect(slimming.calls, hasLength(1));
    expect(slimming.calls.single.udid, 'UDID');
    expect(
      slimming.calls.single.except,
      {SlimmingCategory.store, SlimmingCategory.photos, SlimmingCategory.web},
      reason: 'the categories a Flutter app is most likely to need',
    );
    expect(
      slimming.calls.single.boot,
      isFalse,
      reason: 'booting is bootAndWait\'s job — a starting device cannot answer',
    );
    expect(simctl.booted, ['UDID']);
  });

  test('slimming switched off leaves the device alone', () async {
    final slimming = _RecordingSlimming();
    final simctl = _RecordingSimctl();
    final container = containerWith(
      slimming: slimming,
      simctl: simctl,
      enabled: false,
    );

    await container.read(simulatorTransitionsProvider.notifier).boot('UDID');

    expect(slimming.calls, isEmpty);
    expect(simctl.booted, ['UDID']);
  });

  test('a simulator still starts when it cannot be slimmed', () async {
    // Slimming is an optimisation. Refusing to start the simulator because its
    // services could not be trimmed would turn a saving into an outage.
    final slimming = _RecordingSlimming(throws: true);
    final simctl = _RecordingSimctl();
    final container = containerWith(slimming: slimming, simctl: simctl);

    await container.read(simulatorTransitionsProvider.notifier).boot('UDID');

    expect(simctl.booted, ['UDID']);
  });

  test('keeping nothing slims every category', () async {
    final slimming = _RecordingSlimming();
    final simctl = _RecordingSimctl();
    final container = containerWith(
      slimming: slimming,
      simctl: simctl,
      kept: const [],
    );

    await container.read(simulatorTransitionsProvider.notifier).boot('UDID');

    expect(slimming.calls.single.except, isEmpty);
  });
}
