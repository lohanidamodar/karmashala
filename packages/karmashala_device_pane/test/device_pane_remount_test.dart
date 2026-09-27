import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_device_pane/providers.dart';
import 'package:karmashala_device_pane/pane.dart';
import 'package:agent_cli/process.dart';

const _serial = 'F6IZLV6LMFT4U4ZT';

AndroidSdk _sdk() => const AndroidSdk(
  root: EnvironmentPath(environmentId: 'windows', path: r'C:\sdk'),
  adb: EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\sdk\platform-tools\adb.exe',
  ),
  emulator: EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\sdk\emulator\emulator.exe',
  ),
);

AndroidDevice _device({String serial = _serial}) => AndroidDevice(
  serial: serial,
  environmentId: 'windows',
  state: DeviceConnectionState.device,
  model: 'CPH1989',
);

/// Records every start and never finishes one.
///
/// A finished start needs a real [DeviceStreamSession] — private constructor —
/// and then a libmpv `Player`, neither of which exists in a widget test. What
/// these cases are about happens before either: the pane records *which device
/// the live view is for* synchronously, at the top of `_startStream`, and that
/// is the flag which has to survive an unmount.
class _RecordingStreamService implements DeviceStreamService {
  final List<String> starts = <String>[];

  @override
  Future<DeviceStreamSession> start(
    String serial, {
    int? maxSize,
    int? maxFps,
    bool useControlSocket = true,
  }) {
    starts.add(serial);
    return Completer<DeviceStreamSession>().future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('these cases never reach a running stream');
}

/// Stands in for the side panel's body, which builds one surface's widget in
/// place of another's — the gesture that unmounts the pane. The whole shell is
/// not needed to reproduce it, only the swap.
class _SurfaceSwitcher extends StatelessWidget {
  const _SurfaceSwitcher(this.showDevice);

  final ValueListenable<bool> showDevice;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: ValueListenableBuilder<bool>(
        valueListenable: showDevice,
        builder: (context, show, _) =>
            show ? const DevicePane() : const Text('another surface'),
      ),
    ),
  );
}

/// One container for the whole case, because the side panel swapping surfaces
/// does not rebuild the app's `ProviderScope`.
ProviderContainer _container({
  required _RecordingStreamService service,
  required List<AndroidDevice> Function() devices,
}) => ProviderContainer(
  overrides: [
    androidSdkProvider.overrideWith((ref) async => _sdk()),
    androidEmulatorArgumentsProvider.overrideWithValue(const []),
    androidSlimmingServiceProvider.overrideWithValue(null),
    slimmingOnStartProvider.overrideWithValue(false),
    slimmingKeptCategoriesProvider.overrideWithValue(const {}),
    devicesProvider.overrideWith((ref) async => devices()),
    avdsProvider.overrideWith((ref) async => const []),
    deviceScreenSizeProvider.overrideWith((ref, serial) async => null),
    hostCanRunSimulatorsProvider.overrideWithValue(false),
    iosSimulatorsProvider.overrideWith((ref) async => const []),
    simulatorBackendProvider.overrideWithValue(null),
    deviceStreamServiceProvider.overrideWithValue(service),
  ],
);

Future<void> _pumpPane(
  WidgetTester tester,
  ProviderContainer container,
  ValueNotifier<bool> showDevice,
) async {
  tester.view
    ..physicalSize = const Size(1440, 900)
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: _SurfaceSwitcher(showDevice),
    ),
  );
  await tester.pumpAndSettle();
}

/// The spinner is animating from the moment the live view starts, so nothing
/// here can settle. Pumping a fixed number of frames is enough: every step is
/// a microtask on an already-resolved future.
Future<void> _pumpFrames(WidgetTester tester, [int frames = 4]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  group('the Android live view survives the pane being switched away', () {
    testWidgets('it comes back, on the same device', (tester) async {
      final service = _RecordingStreamService();
      final container = _container(
        service: service,
        devices: () => [_device()],
      );
      addTearDown(container.dispose);
      final showDevice = ValueNotifier(true);
      addTearDown(showDevice.dispose);
      await _pumpPane(tester, container, showDevice);

      await tester.tap(find.text('Live view'));
      await _pumpFrames(tester);
      expect(service.starts, [_serial]);

      // Switch the side panel to another surface, and back.
      showDevice.value = false;
      await tester.pumpAndSettle();
      expect(find.byType(DevicePane), findsNothing);
      showDevice.value = true;
      await _pumpFrames(tester);

      expect(service.starts, [_serial, _serial]);
      expect(container.read(androidLiveViewProvider), _serial);
      expect(container.read(selectedDeviceSerialProvider), _serial);
      // What a remount shows until the stream is back: the spinner. The held
      // frame cannot survive — its player went with the old element.
      expect(find.byType(InlineSpinner), findsWidgets);
      expect(find.textContaining('Pick a device below'), findsNothing);
    });

    testWidgets('coming back starts one session, not two', (tester) async {
      // A second scrcpy against a device that already has one is the
      // contention this app has been bitten by before. The resume goes through
      // the same `_starting` and same-serial guards a device switch does.
      final service = _RecordingStreamService();
      final container = _container(
        service: service,
        devices: () => [_device()],
      );
      addTearDown(container.dispose);
      final showDevice = ValueNotifier(true);
      addTearDown(showDevice.dispose);
      await _pumpPane(tester, container, showDevice);

      await tester.tap(find.text('Live view'));
      await _pumpFrames(tester);
      showDevice.value = false;
      await tester.pumpAndSettle();
      showDevice.value = true;
      await _pumpFrames(tester, 20);

      expect(service.starts.length, 2);
    });

    testWidgets('a device unplugged while the pane was away is not resumed', (
      tester,
    ) async {
      final service = _RecordingStreamService();
      // A second device stays plugged in, so what is on screen afterwards is
      // the pane's ordinary "pick one" and not "no Android devices".
      final other = _device(serial: 'emulator-5554');
      var attached = <AndroidDevice>[_device(), other];
      final container = _container(service: service, devices: () => attached);
      addTearDown(container.dispose);
      final showDevice = ValueNotifier(true);
      addTearDown(showDevice.dispose);
      await _pumpPane(tester, container, showDevice);

      await tester.tap(find.byKey(const Key('preview-$_serial')));
      await _pumpFrames(tester);
      expect(service.starts, [_serial]);
      showDevice.value = false;
      await tester.pumpAndSettle();

      // Unplugged while the pane was on another surface.
      attached = [other];
      container.invalidate(devicesProvider);
      await container.read(devicesProvider.future);
      showDevice.value = true;
      await tester.pumpAndSettle();

      expect(service.starts, [_serial]);
      expect(container.read(androidLiveViewProvider), isNull);
      expect(find.textContaining('Pick a device below'), findsOneWidget);
    });
  });
}
