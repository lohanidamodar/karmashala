/// Lifecycle-aware reconnect for the companion.
///
/// On resume the gateway is always asked to reconnect, whatever the link
/// claims. A link that reads "connected" after the app was frozen is a claim
/// about a socket nobody watched: Android may have torn it down, or the NAT
/// binding behind it may be gone, and the transport will not find out until
/// its next heartbeat — twenty-five seconds of a dead link that looks alive.
/// `reconnect()` re-dials a link that is down and PROVES one that says it is
/// up, so the answer is definite either way within one hello. On pause
/// nothing is done at all: the link rests, with no wake-locks and no
/// background service — an FCM wake is the design's background answer.
library;

import 'dart:async' show unawaited;

import 'package:flutter/widgets.dart';

import '../../features/companion/client/companion_gateway.dart';

class CompanionLifecycleReconnector with WidgetsBindingObserver {
  CompanionLifecycleReconnector(this._gateway, {this.onLog});

  final CompanionGateway _gateway;
  final void Function(String message)? onLog;

  WidgetsBinding? _binding;

  /// Starts observing app lifecycle changes.
  void attach([WidgetsBinding? binding]) {
    if (_binding != null) return;
    _binding = binding ?? WidgetsBinding.instance;
    _binding!.addObserver(this);
  }

  void detach() {
    _binding?.removeObserver(this);
    _binding = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    onLog?.call(
      _gateway.link == CompanionLinkState.connected
          ? 'resumed; proving the link rather than trusting it'
          : 'resumed with the link down; re-dialling now',
    );
    unawaited(() async {
      try {
        await _gateway.reconnect();
      } on Object catch (error) {
        onLog?.call('resume reconnect failed: $error');
      }
    }());
  }
}
