/// The real Android multicast lock, over the runner's own MethodChannel.
/// Without it the server's LAN beacon is inaudible.
library;

import 'package:flutter/services.dart';

import 'package:karmashala_remote/client.dart';

/// Counted across every holder in the process: the native lock is one and
/// not reference-counted (`MainActivity.kt`), so a pairing's scout letting
/// go must not deafen the machine in use.
class ChannelMulticastLock implements MulticastLockHolder {
  ChannelMulticastLock({this.onLog});

  /// The channel `MainActivity.kt` answers. Methods: `acquire`, `release`.
  static const MethodChannel channel = MethodChannel(
    'karmashala/multicast_lock',
  );

  static var _holders = 0;

  final void Function(String message)? onLog;
  var _held = false;

  @override
  Future<void> acquire() async {
    if (_held) return;
    _held = true;
    if (_holders++ == 0) await _invoke('acquire');
  }

  @override
  Future<void> release() async {
    if (!_held) return;
    _held = false;
    if (--_holders == 0) await _invoke('release');
  }

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
