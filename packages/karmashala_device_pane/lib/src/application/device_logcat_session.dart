import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_devices/karmashala_devices.dart';

import 'device_ports.dart';
import 'device_providers.dart';

/// `karmashala_devices`' [DeviceLogcatSession] as a Flutter [Listenable], so
/// a builder can listen to it. The session already has the two methods.
class DeviceLogcatListenable extends DeviceLogcatSession implements Listenable {
  DeviceLogcatListenable({
    required super.serial,
    required super.adb,
    required super.clock,
    super.capacity,
  });
}

/// One session per device, disposed with the last widget watching it.
/// `autoDispose` is the whole bound on cost: no watcher, no `logcat`.
final deviceLogcatSessionProvider = Provider.autoDispose
    .family<DeviceLogcatListenable, String>((ref, serial) {
      final session = DeviceLogcatListenable(
        serial: serial,
        adb: ref.watch(adbServiceProvider),
        clock: ref.watch(deviceClockProvider),
      );
      ref.onDispose(session.dispose);
      return session;
    });
