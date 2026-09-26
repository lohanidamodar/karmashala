/// Lifecycle-aware reconnect. On resume the gateway is always asked to
/// reconnect, and every state is reported so a backgrounded phone gets pushes.
library;

import 'dart:async' show unawaited;

import 'package:flutter/widgets.dart';

import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_remote/remote.dart';

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

  /// Whether the app is in front of its owner in [state]. `inactive` counts as
  /// foreground — the app switcher and an incoming call are still on screen.
  static CompanionVisibility visibilityOf(AppLifecycleState state) =>
      switch (state) {
        AppLifecycleState.resumed ||
        AppLifecycleState.inactive => CompanionVisibility.foreground,
        AppLifecycleState.hidden ||
        AppLifecycleState.paused ||
        AppLifecycleState.detached => CompanionVisibility.background,
      };

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Reported first, and for every state: this is the only thing that makes a
    // backgrounded phone reachable by a push at all.
    unawaited(() async {
      try {
        await _gateway.reportVisibility(visibilityOf(state));
      } on Object catch (error) {
        onLog?.call('reporting visibility failed: $error');
      }
    }());
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
