import 'dart:convert';

import 'package:agent_cli/process.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_device_pane/dialogs.dart';
import 'package:karmashala_device_pane/providers.dart';
import 'package:karmashala_ui/theme.dart';

import 'fake_scrcpy_control_channel.dart';
import 'support/fake_command_runner.dart';

/// The files dialog in the smallest window the app allows, holding a file
/// with a real recording's name — where the breadcrumb's Paste label and the
/// row's name compete for one line.
const _name = 'screen-recording-emulator-5554-20260907-100000.mp4';

const _device = AndroidDevice(
  serial: 'emulator-5554',
  environmentId: 'windows',
  state: DeviceConnectionState.device,
);

CommandResult _ls(String listing) => CommandResult(
  exitCode: 0,
  stdout: base64.encode(utf8.encode(listing)),
  stderr: '',
);

FakeCommandRunner _runner() => FakeCommandRunner(
  responder: (request) {
    final command = request.arguments.last;
    if (command.startsWith("ls -la '/sdcard/'")) {
      return _ls(
        'total 8\n'
        '-rw-rw---- 1 u0_a1 media_rw 1234567 2026-09-07 10:00 $_name\n',
      );
    }
    if (command.contains("ls -lad '/sdcard'")) {
      return _ls('drwxrwx--- 2 u0_a1 media_rw 4096 2026-09-07 10:00 /sdcard');
    }
    return const CommandResult(exitCode: 0, stdout: '', stderr: '');
  },
);

void main() {
  for (final scale in [1.0, 1.3]) {
    testWidgets('fits a 720x560 window with a long name held, ${scale}x text', (
      tester,
    ) async {
      tester.view
        ..physicalSize = const Size(720, 560)
        ..devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final runner = _runner();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            deviceFleetProvider.overrideWithValue(
              () async => DeviceFleet(
                adb: AdbService(
                  runner: runner,
                  sdk: const AndroidSdk(
                    root: EnvironmentPath(
                      environmentId: 'windows',
                      path: r'C:\sdk',
                    ),
                    adb: EnvironmentPath(
                      environmentId: 'windows',
                      path: r'C:\sdk\platform-tools\adb.exe',
                    ),
                  ),
                ),
                simctl: null,
                backend: null,
                bootSimulator: (_) async {},
                simulatorIsBusy: (_) => false,
                refreshAndroid: () {},
                refreshSimulators: () {},
              ),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => DeviceFilesDialog(
                        device: _device,
                        host: FakeHostClipboard(),
                        temporaryDirectory: '/tmp',
                        makeDirectory: (_) async {},
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text(_name), findsOneWidget);
      // A right-click opens the row's menu: the `⋮` waits for a hover.
      await tester.tap(find.text(_name), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy on the device'));
      await tester.pumpAndSettle();

      // Held: the breadcrumb now carries "Paste — <name>" beside the path.
      final paste = find.byKey(const Key('device-files-paste'));
      expect(paste.hitTestable(), findsOneWidget);
      expect(
        tester.getSize(find.text(_name)).width,
        greaterThanOrEqualTo(120),
        reason: 'the row keeps its name beside its three actions',
      );
    });
  }
}
