import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_devices/providers.dart';
import 'package:karmashala_devices/devices.dart';
import 'package:karmashala/src/features/devices/application/device_bindings.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';

/// Records what the boot path asked for, so a test can tell "slimmed with these
/// categories" from "slimmed".
class _RecordingSlimming implements AndroidSlimmingService {
  _RecordingSlimming({this.throws = false, this.report});

  final bool throws;
  final AndroidSlimmingReport? report;

  final List<({String serial, Set<AndroidSlimmingCategory> enabled})> applied =
      [];
  final List<String> restored = [];

  @override
  Future<AndroidSlimmingReport> apply(
    String serial, {
    Set<AndroidSlimmingCategory> enabled = const {},
  }) async {
    applied.add((serial: serial, enabled: enabled));
    if (throws) throw StateError('adb went away');
    return report ?? const AndroidSlimmingReport();
  }

  @override
  Future<AndroidSlimmingReport> restore(String serial) async {
    restored.add(serial);
    if (throws) throw StateError('adb went away');
    return report ?? const AndroidSlimmingReport();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('only apply and restore are used here');
}

class _StaticSettings extends SettingsController {
  _StaticSettings(this._settings);
  final Settings _settings;

  @override
  Settings build() => _settings;
}

ProviderContainer _container({
  Settings settings = const Settings(),
  _RecordingSlimming? slimming,
}) {
  final container = ProviderContainer(
    overrides: [
      // The app's half of `karmashala_devices`: its clock, its runner
      // factory, its settings and its shell, behind the package's ports.
      ...deviceBindings,
      settingsControllerProvider.overrideWith(() => _StaticSettings(settings)),
      androidSlimmingServiceProvider.overrideWithValue(slimming),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('emulator arguments', () {
    test('carry the default flags with no renderer override', () async {
      final container = _container();
      expect(container.read(androidEmulatorArgumentsProvider), [
        '-no-audio',
        '-no-metrics',
        '-no-passive-gps',
      ]);
    });

    test(
      'drop the slimming flags but keep the renderer when slimming is off',
      () async {
        // The renderer is a choice about this pane's preview, not an
        // optimisation, so switching slimming off must not silently swap it back.
        final container = _container(
          settings: const Settings(
            androidSlimming: false,
            androidEmulatorGpu: 'swiftshader',
          ),
        );
        expect(container.read(androidSlimmingCategoriesProvider), isEmpty);
        expect(container.read(androidEmulatorArgumentsProvider), [
          '-gpu',
          'swiftshader',
        ]);
      },
    );

    test('a saved category this build dropped is ignored', () async {
      final container = _container(
        settings: const Settings(
          androidSlimmingEnabled: ['audio', 'a-category-from-the-future'],
        ),
      );
      expect(container.read(androidSlimmingCategoriesProvider), {
        AndroidSlimmingCategory.audio,
      });
      expect(container.read(androidEmulatorArgumentsProvider), ['-no-audio']);
    });
  });

  group('applyAfterBoot', () {
    test('passes the selected categories to the service', () async {
      final slimming = _RecordingSlimming();
      final container = _container(
        slimming: slimming,
        settings: const Settings(androidSlimmingEnabled: ['animations', 'gms']),
      );

      await container
          .read(androidSlimmingProvider.notifier)
          .applyAfterBoot('emulator-5554');

      expect(slimming.applied, hasLength(1));
      expect(slimming.applied.single.serial, 'emulator-5554');
      expect(slimming.applied.single.enabled, {
        AndroidSlimmingCategory.animations,
        AndroidSlimmingCategory.playServices,
      });
    });

    test('does nothing at all when slimming is off', () async {
      final slimming = _RecordingSlimming();
      final container = _container(
        slimming: slimming,
        settings: const Settings(androidSlimming: false),
      );

      await container
          .read(androidSlimmingProvider.notifier)
          .applyAfterBoot('emulator-5554');

      expect(slimming.applied, isEmpty);
    });

    test('a slimming failure never reaches the boot', () async {
      // Slimming is an optimisation. Letting it throw here would abort the
      // boot in `device_pane`, turning a saving into an outage — the rule the
      // iOS side states and the reason it is repeated for Android.
      final slimming = _RecordingSlimming(throws: true);
      final container = _container(slimming: slimming);

      await expectLater(
        container
            .read(androidSlimmingProvider.notifier)
            .applyAfterBoot('emulator-5554'),
        completion(isNull),
      );
      expect(slimming.applied, hasLength(1));
    });

    test('a partly refused run is reported, not thrown', () async {
      final slimming = _RecordingSlimming(
        report: const AndroidSlimmingReport(
          applied: ['window_animation_scale'],
          failed: {'com.google.android.videos': 'Unknown package'},
        ),
      );
      final container = _container(slimming: slimming);

      final report = await container
          .read(androidSlimmingProvider.notifier)
          .applyAfterBoot('emulator-5554');

      expect(report, isNotNull);
      expect(report!.ok, isFalse);
      expect(report.failed.keys, ['com.google.android.videos']);
    });

    test('is inert when there is no Android SDK', () async {
      final container = _container();
      expect(
        await container
            .read(androidSlimmingProvider.notifier)
            .applyAfterBoot('emulator-5554'),
        isNull,
      );
    });
  });

  group('restore', () {
    test('runs even with the master switch off', () async {
      // This is precisely the case a user cannot otherwise get out of: they
      // turned slimming off and their emulator stayed broken.
      final slimming = _RecordingSlimming();
      final container = _container(
        slimming: slimming,
        settings: const Settings(androidSlimming: false),
      );

      await container
          .read(androidSlimmingProvider.notifier)
          .restore('emulator-5554');

      expect(slimming.restored, ['emulator-5554']);
    });

    test('a failure is swallowed the same way', () async {
      final slimming = _RecordingSlimming(throws: true);
      final container = _container(slimming: slimming);
      await expectLater(
        container
            .read(androidSlimmingProvider.notifier)
            .restore('emulator-5554'),
        completion(isNull),
      );
    });

    test('leaves no serial marked busy afterwards', () async {
      final slimming = _RecordingSlimming(throws: true);
      final container = _container(slimming: slimming);
      await container
          .read(androidSlimmingProvider.notifier)
          .restore('emulator-5554');
      expect(container.read(androidSlimmingProvider), isEmpty);
    });
  });
}
