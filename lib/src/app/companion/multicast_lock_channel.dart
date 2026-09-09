/// The real Android multicast lock, over the companion runner's own
/// MethodChannel (`MainActivity.kt`) — not a plugin.
///
/// Android drops multicast datagrams unless a `WifiManager.MulticastLock` is
/// held, so without this the desktop's LAN beacon is inaudible. Best-effort
/// by design: on any platform where the channel does not exist (desktop,
/// tests, iOS) every call completes quietly and the scout stays relay-only.
library;

import 'package:flutter/services.dart';

import 'package:karmashala_remote/client.dart';

class ChannelMulticastLock implements MulticastLockHolder {
  ChannelMulticastLock({this.onLog});

  /// The channel `MainActivity.kt` answers. Methods: `acquire`, `release`.
  static const MethodChannel channel = MethodChannel(
    'karmashala/multicast_lock',
  );

  final void Function(String message)? onLog;

  @override
  Future<void> acquire() => _invoke('acquire');

  @override
  Future<void> release() => _invoke('release');

  Future<void> _invoke(String method) async {
    try {
      await channel.invokeMethod<void>(method);
    } on MissingPluginException {
      onLog?.call('multicast lock channel absent; $method skipped');
    } on PlatformException catch (error) {
      onLog?.call('multicast lock $method failed: ${error.code}');
    }
  }
}
