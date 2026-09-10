/// The real Android multicast lock, over the companion runner's own
/// MethodChannel. Without it the desktop's LAN beacon is inaudible.
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
