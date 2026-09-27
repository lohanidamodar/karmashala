import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_providers.dart';
import 'terminal_sessions_controller.dart';

/// How often a person acting in this window is said to the server, at most.
const Duration kClientActivePeriod = Duration(seconds: 5);

/// **Tells the server a person is using this window** (slice 5b), and which
/// pane is in front of them: what the server asks a window to show goes to
/// the one a person last used. A key or a pointer press, at most once per
/// [kClientActivePeriod]; nothing is said while nobody acts. Must be watched.
class ClientPresence extends Notifier<void> {
  DateTime? _lastSaid;

  @override
  void build() {
    bool onKey(KeyEvent _) {
      _acted();
      return false;
    }

    void onPointer(PointerEvent event) {
      if (event is PointerDownEvent) _acted();
    }

    HardwareKeyboard.instance.addHandler(onKey);
    GestureBinding.instance.pointerRouter.addGlobalRoute(onPointer);
    ref.onDispose(() {
      HardwareKeyboard.instance.removeHandler(onKey);
      GestureBinding.instance.pointerRouter.removeGlobalRoute(onPointer);
    });
  }

  void _acted() {
    final now = DateTime.now();
    final last = _lastSaid;
    if (last != null && now.difference(last) < kClientActivePeriod) return;
    _lastSaid = now;
    final state = ref.read(terminalSessionsControllerProvider);
    final tab = state.tabs.where((t) => t.id == state.activeTabId).firstOrNull;
    unawaited(
      ref
          .read(dataClientProvider)
          .send(ClientActive(focusedPaneId: tab?.focusedPaneId))
          .then((_) {}, onError: (Object _) {}),
    );
  }
}

final clientPresenceProvider = NotifierProvider<ClientPresence, void>(
  ClientPresence.new,
);
