/// Lifecycle-aware reconnect for the companion.
///
/// On resume with the link down, re-dial immediately instead of waiting out
/// the backoff. While foregrounded the gateway's own backoff governs. On
/// pause nothing is done at all: the link rests, with no wake-locks and no
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
    if (_gateway.link == CompanionLinkState.connected) return;
    onLog?.call('resumed with the link down; re-dialling now');
    unawaited(() async {
      try {
        await _gateway.reconnect();
      } on Object catch (error) {
        onLog?.call('resume reconnect failed: $error');
      }
    }());
  }
}
