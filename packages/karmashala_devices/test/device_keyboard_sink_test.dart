import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:karmashala_devices/src/data/adb_service.dart';
import 'package:karmashala_devices/src/data/device_keyboard_sink.dart';
import 'package:karmashala_devices/src/data/scrcpy_control.dart';
import 'package:karmashala_devices/src/domain/android_device.dart';
import 'package:karmashala_devices/src/domain/device_keyboard.dart';
import 'package:agent_cli/process.dart';

import './support/fake_command_runner.dart';

AndroidSdk _sdk() => const AndroidSdk(
  root: EnvironmentPath(environmentId: 'windows', path: r'C:\sdk'),
  adb: EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\sdk\platform-tools\adb.exe',
  ),
);

/// A real loopback socket pair, so what is asserted is the shipped encoder's
/// bytes as the server would read them.
class _Wire {
  _Wire(this.server, this.client, this.received);

  final ServerSocket server;
  final Socket client;
  final List<int> received;

  static Future<_Wire> open() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final received = <int>[];
    final accepted = server.first;
    final client = await Socket.connect('127.0.0.1', server.port);
    (await accepted).listen(received.addAll);
    return _Wire(server, client, received);
  }

  Future<void> close() async {
    client.destroy();
    await server.close();
  }

  Uint8List get bytes => Uint8List.fromList(received);
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 40));

void main() {
  group('ScrcpyKeyboardSink', () {
    test('a printable string arrives as one INJECT_TEXT message', () async {
      final wire = await _Wire.open();
      addTearDown(wire.close);
      final sink = ScrcpyKeyboardSink(
        connection: ScrcpyControlConnection(wire.client),
      );

      sink.send(const DeviceTextIntent('hi'));
      await _settle();

      final bytes = wire.bytes;
      expect(bytes.first, ScrcpyControlType.injectText);
      expect(ByteData.sublistView(bytes).getUint32(1), 2);
      expect(bytes.sublist(5), 'hi'.codeUnits);
    });

    test('a keycode arrives as a 14-byte INJECT_KEYCODE', () async {
      final wire = await _Wire.open();
      addTearDown(wire.close);
      final sink = ScrcpyKeyboardSink(
        connection: ScrcpyControlConnection(wire.client),
      );

      sink.send(
        const DeviceKeycodeIntent(
          action: AndroidKeyAction.down,
          keyCode: AndroidKeyCode.del,
          metaState: AndroidMetaState.ctrlOn,
        ),
      );
      await _settle();

      final bytes = wire.bytes;
      expect(bytes.length, kScrcpyKeycodeMessageLength);
      final view = ByteData.sublistView(bytes);
      expect(view.getUint8(0), ScrcpyControlType.injectKeycode);
      expect(view.getUint8(1), AndroidKeyAction.down);
      expect(view.getInt32(2), AndroidKeyCode.del);
      expect(view.getInt32(10), AndroidMetaState.ctrlOn);
    });

    test('a long paste is split rather than refused by the server', () async {
      final wire = await _Wire.open();
      addTearDown(wire.close);
      final sink = ScrcpyKeyboardSink(
        connection: ScrcpyControlConnection(wire.client),
      );

      sink.send(DeviceTextIntent('a' * 400));
      await _settle();

      final bytes = wire.bytes;
      final firstLength = ByteData.sublistView(bytes).getUint32(1);
      expect(firstLength, kScrcpyInjectTextMaxBytes);
      // Two messages: 300 bytes then 100.
      final secondAt = 5 + kScrcpyInjectTextMaxBytes;
      expect(bytes[secondAt], ScrcpyControlType.injectText);
      expect(ByteData.sublistView(bytes).getUint32(secondAt + 1), 100);
    });

    test('a dead socket tells the caller instead of dropping the key', () async {
      final wire = await _Wire.open();
      var dropped = false;
      final connection = ScrcpyControlConnection(wire.client);
      final sink = ScrcpyKeyboardSink(
        connection: connection,
        onDropped: () => dropped = true,
      );
      await connection.close();
      await wire.close();

      expect(sink.send(const DeviceTextIntent('x')), isFalse);
      expect(dropped, isTrue);
    });

    test('reports itself as the continuous transport', () async {
      final wire = await _Wire.open();
      addTearDown(wire.close);
      final sink = ScrcpyKeyboardSink(
        connection: ScrcpyControlConnection(wire.client),
      );
      expect(sink.transport, DeviceKeyboardTransport.scrcpyControl);
      expect(sink.transport.carriesModifiers, isTrue);
    });
  });

  group('AdbKeyboardSink', () {
    test('text goes through `input text`, escaped', () async {
      final runner = FakeCommandRunner();
      final sink = AdbKeyboardSink(
        adb: AdbService(runner: runner, sdk: _sdk()),
        serial: 'emulator-5554',
      );

      expect(sink.send(const DeviceTextIntent('a b')), isTrue);
      await _settle();

      expect(
        runner.requests.single.arguments,
        ['-s', 'emulator-5554', 'shell', 'input', 'text', 'a%sb'],
      );
    });

    test('a key press goes through `input keyevent`, once, on the down', () async {
      // `input keyevent` synthesises a whole press. Sending it again on the up
      // would type the key twice.
      final runner = FakeCommandRunner();
      final sink = AdbKeyboardSink(
        adb: AdbService(runner: runner, sdk: _sdk()),
        serial: 'emulator-5554',
      );

      sink.send(
        const DeviceKeycodeIntent(
          action: AndroidKeyAction.down,
          keyCode: AndroidKeyCode.del,
        ),
      );
      sink.send(
        const DeviceKeycodeIntent(
          action: AndroidKeyAction.up,
          keyCode: AndroidKeyCode.del,
        ),
      );
      await _settle();

      expect(runner.requests, hasLength(1));
      expect(runner.requests.single.arguments, [
        '-s',
        'emulator-5554',
        'shell',
        'input',
        'keyevent',
        '${AndroidKeyCode.del}',
      ]);
    });

    test('a modifier chord is refused out loud, not sent bare', () async {
      // `input keyevent` has no meta state at all. Sending KEYCODE_A alone for
      // Ctrl+A would type "a" into whatever the user meant to select.
      final runner = FakeCommandRunner();
      final refused = <DeviceKeycodeIntent>[];
      final sink = AdbKeyboardSink(
        adb: AdbService(runner: runner, sdk: _sdk()),
        serial: 'emulator-5554',
        onUnsupported: refused.add,
      );

      expect(
        sink.send(
          const DeviceKeycodeIntent(
            action: AndroidKeyAction.down,
            keyCode: AndroidKeyCode.a,
            metaState: AndroidMetaState.ctrlOn,
          ),
        ),
        isFalse,
      );
      await _settle();

      expect(runner.requests, isEmpty);
      expect(refused.single.keyCode, AndroidKeyCode.a);
    });

    test('a shift chord still goes, because the character carries it', () async {
      // Shift alone is expressible: the printable path already produced the
      // shifted character, and a shifted navigation key is a selection.
      final runner = FakeCommandRunner();
      final sink = AdbKeyboardSink(
        adb: AdbService(runner: runner, sdk: _sdk()),
        serial: 'emulator-5554',
      );
      expect(
        sink.send(
          const DeviceKeycodeIntent(
            action: AndroidKeyAction.down,
            keyCode: AndroidKeyCode.dpadLeft,
            metaState: AndroidMetaState.shiftOn,
          ),
        ),
        isTrue,
      );
      await _settle();
      expect(runner.requests, hasLength(1));
    });

    test('reports itself as the transport that cannot carry modifiers', () {
      final sink = AdbKeyboardSink(
        adb: AdbService(runner: FakeCommandRunner(), sdk: _sdk()),
        serial: 'emulator-5554',
      );
      expect(sink.transport, DeviceKeyboardTransport.adbInput);
      expect(sink.transport.carriesModifiers, isFalse);
    });
  });
}
