/// Lifecycle-aware reconnect for the companion.
///
/// On resume the gateway is always asked to reconnect, whatever the link
/// claims. A link that reads "connected" after the app was frozen is a claim
/// about a socket nobody watched: Android may have torn it down, or the NAT
/// binding behind it may be gone, and the transport will not find out until
/// its next heartbeat — twenty-five seconds of a dead link that looks alive.
/// `reconnect()` re-dials a link that is down and PROVES one that says it is
/// up, so the answer is definite either way within one hello. On pause no
/// dialling is done at all: the link rests, with no wake-locks and no
/// background service — an FCM wake is the design's background answer.
///
/// **Every state is reported, though, and that is the other half.** The FCM
/// wake only arrives if the desktop sends one, and it used to withhold every
/// push from a phone whose link was up — including a phone in a pocket, which
/// heard the news into a window nobody could see. So each lifecycle change
/// tells the gateway whether this app is on screen; the gateway sends one
/// `notifications.register` frame per *change* of answer, and nothing here is
/// a tick.
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

  /// Whether the app is in front of its owner in [state].
  ///
  /// `inactive` counts as foreground: it is the app-switcher and the
  /// incoming-call state, where the app is still on screen. Everything from
  /// `hidden` down is not.
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
