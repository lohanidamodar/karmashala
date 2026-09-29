/// The device's default network changing under the link (Wi-Fi to mobile, a
/// new Wi-Fi), as the Android runner reports it over its own EventChannel.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// The channel `MainActivity.kt` answers: one event per default network it
/// reports, its id, or `none` when there is no network at all.
const EventChannel kNetworkChannel = EventChannel('karmashala/network');

/// How long the reports settle before a change is acted on: a switch comes
/// as a burst, and one proof is enough.
const Duration kNetworkSettle = Duration(milliseconds: 750);

/// Fires once per change to a network that is up, never for the first report
/// (the network the app started on). Empty where no runner reports networks
/// (every platform but Android), so a desktop never asks.
Stream<void> networkChanges({void Function(String message)? onLog}) {
  if (kIsWeb || !Platform.isAndroid) return const Stream<void>.empty();
  late final StreamController<void> out;
  StreamSubscription<Object?>? reports;
  Timer? settle;
  String? last;
  out = StreamController<void>(
    onListen: () {
      reports = kNetworkChannel.receiveBroadcastStream().listen(
        (report) {
          final id = '$report';
          final first = last == null;
          if (id == last) return;
          last = id;
          if (first || id == 'none') return;
          settle?.cancel();
          settle = Timer(kNetworkSettle, () {
            onLog?.call('The network changed; proving the link.');
            if (!out.isClosed) out.add(null);
          });
        },
        onError: (Object error) =>
            onLog?.call('network change reports unavailable: $error'),
      );
    },
    onCancel: () async {
      settle?.cancel();
      await reports?.cancel();
    },
  );
  return out.stream;
}
