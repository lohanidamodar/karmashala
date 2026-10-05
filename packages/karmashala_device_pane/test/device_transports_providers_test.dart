import 'package:agent_cli/process.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_device_pane/providers.dart';

import 'support/fake_command_runner.dart';

const _sdk = AndroidSdk(
  root: EnvironmentPath(environmentId: 'windows', path: r'C:\sdk'),
  adb: EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\sdk\platform-tools\adb.exe',
  ),
);

const _usb = '2B071FDH300JJ9';
const _wireless = 'adb-2B071FDH300JJ9-zcg43M._adb-tls-connect._tcp';

/// A phone on a cable and on wireless adb is one row in the pane and the
/// sidebar, and choosing it by either serial chooses that row.
void main() {
  ProviderContainer container() {
    final runner = FakeCommandRunner(
      responder: (request) => const CommandResult(
        exitCode: 0,
        stdout:
            'List of devices attached\n'
            '$_usb\tdevice usb:1-1 product:CPH1989 model:CPH1989 '
            'device:OP4B80L1 transport_id:3\n'
            '$_wireless\tdevice product:CPH1989 model:CPH1989 '
            'device:OP4B80L1 transport_id:4\n',
        stderr: '',
      ),
    );
    final container = ProviderContainer(
      overrides: [
        androidSdkProvider.overrideWith((ref) async => _sdk),
        adbServiceProvider.overrideWithValue(
          AdbService(runner: runner, sdk: _sdk),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('one phone over two transports is one device', () async {
    final devices = await container().read(devicesProvider.future);
    expect(devices, hasLength(1));
    expect(devices.single.serial, _usb);
    expect(devices.single.otherSerials, [_wireless]);
  });

  test('chosen by its wireless serial, the one row is selected', () async {
    final c = container();
    await c.read(devicesProvider.future);
    c.read(selectedDeviceSerialProvider.notifier).select(_wireless);
    expect(c.read(selectedDeviceProvider)?.serial, _usb);
  });
}
