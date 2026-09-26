import 'package:karmashala/src/app/companion/multicast_lock_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ChannelMulticastLock.channel, null);
  });

  test('acquires and releases over the runner channel', () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ChannelMulticastLock.channel, (call) async {
          calls.add(call.method);
          return null;
        });
    final lock = ChannelMulticastLock();

    await lock.acquire();
    await lock.release();

    expect(calls, ['acquire', 'release']);
  });

  test('a platform refusal is logged and swallowed', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ChannelMulticastLock.channel, (call) async {
          throw PlatformException(code: 'wifi-off');
        });
    final log = <String>[];
    final lock = ChannelMulticastLock(onLog: log.add);

    await lock.acquire();

    expect(log.single, 'multicast lock acquire failed: wifi-off');
  });

  test('a missing channel (desktop, tests) is quietly skipped', () async {
    final log = <String>[];
    final lock = ChannelMulticastLock(onLog: log.add);

    // No handler mocked: exactly what a non-Android runner looks like.
    await lock.acquire();
    await lock.release();

    expect(log, [
      'multicast lock channel absent; acquire skipped',
      'multicast lock channel absent; release skipped',
    ]);
  });
}
