import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/devices/application/device_providers.dart';
import 'package:karmashala_devices/devices.dart';
import 'package:karmashala/src/features/devices/presentation/android_slimming_dialog.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';

const _slimmed = 'emulator-5554';
const _stock = 'emulator-5556';
const _phone = 'F6IZLV6LMFT4U4ZT';

AndroidDevice _device(String serial, {String? model}) => AndroidDevice(
  serial: serial,
  environmentId: 'windows',
  state: DeviceConnectionState.device,
  model: model,
);

AndroidSlimmingStatus _status(
  String serial, {
  Set<String> disabled = const {},
  bool animationsZeroed = false,
}) => AndroidSlimmingStatus(
  serial: serial,
  disabledPackages: disabled,
  settings: {
    'window_animation_scale': animationsZeroed ? '0' : null,
    'transition_animation_scale': animationsZeroed ? '0' : null,
    'animator_duration_scale': animationsZeroed ? '0' : null,
  },
);

/// Answers `status` from a per-serial queue, so a test can say what a device
/// looked like *before* Restore and what it looks like after.
class _FakeSlimming implements AndroidSlimmingService {
  _FakeSlimming({
    this.answers = const {},
    this.fails = false,
    this.hangs = false,
  });

  final Map<String, List<AndroidSlimmingStatus>> answers;
  final bool fails;
  final bool hangs;

  final List<String> restored = [];

  @override
  Future<AndroidSlimmingStatus> status(String serial) {
    if (hangs) return Completer<AndroidSlimmingStatus>().future;
    if (fails) throw StateError('device offline');
    final queue = answers[serial] ?? [_status(serial)];
    return Future.value(queue.length == 1 ? queue.first : queue.removeAt(0));
  }

  @override
  Future<AndroidSlimmingReport> restore(String serial) async {
    restored.add(serial);
    return const AndroidSlimmingReport(applied: ['window_animation_scale']);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('only status and restore are used here');
}

class _StaticSettings extends SettingsController {
  _StaticSettings(this._settings);
  final Settings _settings;

  @override
  Settings build() => _settings;
}

Future<void> _pump(
  WidgetTester tester, {
  required List<AndroidDevice> devices,
  required _FakeSlimming slimming,
}) async {
  tester.view
    ..physicalSize = const Size(1440, 1200)
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsControllerProvider.overrideWith(
          () => _StaticSettings(const Settings()),
        ),
        androidSlimmingServiceProvider.overrideWithValue(slimming),
        devicesProvider.overrideWith((ref) async => devices),
      ],
      child: const MaterialApp(
        home: Scaffold(body: AndroidSlimmingDialog()),
      ),
    ),
  );
  await tester.pump();
}

Finder _restoreFor(String serial) =>
    find.byKey(Key('android-slimming-restore-$serial'));

String _statusFor(WidgetTester tester, String serial) => tester
    .widget<Text>(find.byKey(Key('android-slimming-status-$serial')))
    .data!;

void main() {
  group('the Restore row', () {
    testWidgets('offers Restore only where something was applied', (
      tester,
    ) async {
      // The dialog used to offer Restore for every running emulator, so an
      // emulator that was never slimmed and one whose Play services are
      // disabled looked exactly alike.
      await _pump(
        tester,
        devices: [
          _device(_slimmed, model: 'Pixel slimmed'),
          _device(_stock, model: 'Pixel stock'),
          _device(_phone, model: 'the owner\'s phone'),
        ],
        slimming: _FakeSlimming(
          answers: {
            _slimmed: [
              _status(
                _slimmed,
                animationsZeroed: true,
                disabled: const {'com.google.android.gms'},
              ),
            ],
            _stock: [_status(_stock)],
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(_restoreFor(_slimmed), findsOneWidget);
      expect(_restoreFor(_stock), findsNothing);
      // A physical device is not listed at all: nothing here has touched one.
      expect(_restoreFor(_phone), findsNothing);
    });

    testWidgets('says what is on each emulator', (tester) async {
      await _pump(
        tester,
        devices: [_device(_slimmed), _device(_stock)],
        slimming: _FakeSlimming(
          answers: {
            _slimmed: [
              _status(
                _slimmed,
                animationsZeroed: true,
                // One of ours and one somebody else disabled.
                disabled: const {'com.google.android.gms', 'com.android.nfc'},
              ),
            ],
            _stock: [_status(_stock)],
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(
        _statusFor(tester, _slimmed),
        'This app has 3 settings and 1 disabled package on it. '
        '1 package something else disabled is left alone.',
      );
      expect(_statusFor(tester, _stock), 'Nothing this app applied is on it.');
    });

    testWidgets('an unread device is not treated as a clean one', (
      tester,
    ) async {
      // Unknown is not "nothing": while the device is still being asked there
      // is nothing to offer a restore for yet.
      await _pump(
        tester,
        devices: [_device(_slimmed)],
        slimming: _FakeSlimming(hangs: true),
      );
      await tester.pump();

      expect(_statusFor(tester, _slimmed), 'Checking what is applied…');
      expect(_restoreFor(_slimmed), findsNothing);
    });

    testWidgets('a device that never answered can still be restored', (
      tester,
    ) async {
      // The one case where Restore is offered without knowing: a restore the
      // user cannot reach is worse than one they did not need.
      await _pump(
        tester,
        devices: [_device(_slimmed)],
        slimming: _FakeSlimming(fails: true),
      );
      await tester.pumpAndSettle();

      expect(
        _statusFor(tester, _slimmed),
        'Could not read what is applied — the emulator did not answer.',
      );
      expect(_restoreFor(_slimmed), findsOneWidget);
    });

    testWidgets('restoring re-reads the device, so the offer goes away', (
      tester,
    ) async {
      final slimming = _FakeSlimming(
        answers: {
          _slimmed: [
            _status(_slimmed, animationsZeroed: true),
            _status(_slimmed),
          ],
        },
      );
      await _pump(tester, devices: [_device(_slimmed)], slimming: slimming);
      await tester.pumpAndSettle();
      expect(_restoreFor(_slimmed), findsOneWidget);

      // The Restore row is below the categories, off-screen until scrolled to.
      await tester.ensureVisible(_restoreFor(_slimmed));
      await tester.pumpAndSettle();
      await tester.tap(_restoreFor(_slimmed));
      await tester.pumpAndSettle();

      expect(slimming.restored, [_slimmed]);
      expect(_statusFor(tester, _slimmed), 'Nothing this app applied is on it.');
      expect(
        _restoreFor(_slimmed),
        findsNothing,
        reason: 'a second press would change nothing',
      );
    });

    testWidgets('says what to do when no emulator is running', (tester) async {
      await _pump(
        tester,
        devices: [_device(_phone)],
        slimming: _FakeSlimming(),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Start the emulator you want to put back'),
        findsOneWidget,
      );
    });
  });
}
