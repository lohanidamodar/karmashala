import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:karmashala_core/logging.dart';

import 'server_session.dart';

/// The link to a server elsewhere follows the app on a phone (Stage 1 step
/// 11): in the background it is held for the resume grace, then hung up;
/// back in front it is proved or redialled at once; a network change proves
/// it too. The session also sets `windowFocusedProvider` from it: the phone's
/// "in front" (Stage 3 step 1). Attached only where the OS puts the app in
/// the background — a desktop window that is minimised keeps its link as it
/// is, and its focus stays the window's.
///
/// Reads [currentServerSession] on each event, so a switch of server needs
/// nothing from here.
class LinkLifecycle with WidgetsBindingObserver {
  LinkLifecycle({
    this._networkChanges = const Stream<void>.empty(),
    ServerSession? Function()? session,
    AppLogger? logger,
  }) : _session = session ?? (() => currentServerSession),
       _log = logger ?? AppLogger.named('link_lifecycle');

  final Stream<void> _networkChanges;
  final ServerSession? Function() _session;
  final AppLogger _log;

  WidgetsBinding? _binding;
  StreamSubscription<void>? _network;
  var _background = false;

  void attach([WidgetsBinding? binding]) {
    if (_binding != null) return;
    _binding = binding ?? WidgetsBinding.instance;
    _binding!.addObserver(this);
    final state = _binding!.lifecycleState;
    _background =
        state == AppLifecycleState.hidden || state == AppLifecycleState.paused;
    _network = _networkChanges.listen((_) {
      if (!_background) _session()?.networkChanged();
    });
  }

  /// A session opened while the app is in the background — at start, or a
  /// switch that finished there — rests at once: the event it would have
  /// heard has already passed.
  void adopt(ServerSession session) {
    if (_binding != null && _background) session.appBackgrounded();
  }

  void detach() {
    _binding?.removeObserver(this);
    _binding = null;
    unawaited(_network?.cancel());
    _network = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        if (_background) return;
        _background = true;
        _log.info('In the background; the link is held for the resume grace.');
        _session()?.appBackgrounded();
      case AppLifecycleState.resumed:
        if (!_background) return;
        _background = false;
        _log.info('Back in front; proving the link.');
        _session()?.appForegrounded();
      // `inactive` is still on screen (the app switcher, a call); `detached`
      // is the engine going, which the session's own close handles.
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
  }
}
