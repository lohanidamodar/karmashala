/// This app's half of the phone companion when the session host serves it:
/// it answers the calls the host forwards, and carries where the app's
/// embedded relay is, the desktop's news, pairing requests and the server
/// config calls (`server.config.get` / `set`) the other way.
library;

import 'dart:async';

import 'package:karmashala_companion_server/karmashala_companion_server.dart'
    show CompanionCallDispatcher;
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_host/lifecycle_client.dart';
import 'package:karmashala_remote/host.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/remote.dart';

import '../../sessions/application/host_lifecycle/host_lifecycle_source.dart';
import '../../sessions/application/host_lifecycle/host_lifecycle_subscriber.dart';
import 'pairing_in_progress.dart';

class HostCompanionLink implements HostCompanionPeer {
  HostCompanionLink({
    required RemoteHostBindings Function() bindings,
    required this.deviceById,
    this.onAttached,
    AppLogger? logger,
  }) : _dispatcher = CompanionCallDispatcher(bindings),
       _log = logger ?? AppLogger.named('remote.host');

  final CompanionCallDispatcher _dispatcher;

  /// The device a pairing recorded, read back from the server once the host
  /// says it paired.
  final Future<PairedDevice?> Function(String deviceId) deviceById;

  /// A link to a host opened — maybe a new host: what it serves by is read
  /// again.
  final void Function()? onAttached;

  final AppLogger _log;

  HostLifecycleFeed? _feed;
  StreamSubscription<CompanionCallMessage>? _calls;
  StreamSubscription<CompanionEventMessage>? _events;
  String? _localRelayUrl;
  final Map<int, Completer<PairedDevice>> _pairings = {};

  /// Whether a link to the host is open, so pairing can be asked for.
  bool get connected => _feed != null;

  @override
  void attached(HostLifecycleFeed feed) {
    _stopListening();
    _feed = feed;
    _calls = feed.companionCalls.listen((call) => unawaited(_run(feed, call)));
    _events = feed.companionEvents.listen(_onEvent);
    // Every link, not just the first: the host may be a new one. This app is
    // the one phones' calls are forwarded to whenever it is connected.
    feed.attachCompanion(localRelayUrl: _localRelayUrl);
    onAttached?.call();
  }

  @override
  void detached() {
    _stopListening();
    _feed = null;
    _failPairings('the session host went away before a phone paired');
  }

  /// Where this app's embedded relay listens from now on (null: none) — sent
  /// at once when a link is open, and on every link after.
  void setLocalRelay(Uri? localRelay) {
    final url = localRelay?.toString();
    if (url == _localRelayUrl) return;
    _localRelayUrl = url;
    _feed?.attachCompanion(localRelayUrl: _localRelayUrl);
  }

  /// Asks the server one administrative question (`ServerMethod`). Throws
  /// [StateError] with the reason when there is no link, or the server
  /// refuses.
  Future<Map<String, Object?>> serverCall(
    String method, [
    Map<String, Object?> arguments = const {},
  ]) async {
    final feed = _feed;
    if (feed == null) {
      throw StateError('The session host is not running.');
    }
    try {
      return await feed.serverCall(method, arguments);
    } on HostLifecycleWatchRefused catch (refusal) {
      throw StateError(refusal.message);
    }
  }

  /// News from the desktop; dropped while no link is open, when the host
  /// reads what it needs from its own feed.
  void notice(CompanionNoticeMessage notice) => _feed?.noticeCompanion(notice);

  /// Opens a pairing window at the host. Throws [StateError] with the reason
  /// when it will not open one.
  Future<PairingInProgress> pair({
    required CapabilitySet capabilities,
    Uri? relay,
    bool relayIsLocal = false,
  }) async {
    final feed = _feed;
    if (feed == null) {
      throw StateError(
        'The session host is not running. Start it in Settings, then pair.',
      );
    }
    final PairedMessage window;
    try {
      window = await feed.pairCompanion(
        capabilities: capabilities.bits,
        relay: relay?.toString() ?? '',
        relayIsLocal: relayIsLocal,
      );
    } on HostLifecycleWatchRefused catch (refusal) {
      throw StateError(refusal.message);
    }
    final done = Completer<PairedDevice>();
    // A window the dialog stopped watching still ends; nobody need hear it.
    done.future.ignore();
    _pairings[window.requestId] = done;
    return PairingInProgress(
      payload: PairingPayload.decode(window.payload),
      done: done.future,
    );
  }

  /// Closes the window the dialog showed: its secret dies with it.
  void cancelPairing() {
    notice(const CompanionNoticeMessage(CompanionNoticeKind.pairingCancelled));
    _failPairings('pairing was cancelled');
  }

  void _onEvent(CompanionEventMessage event) {
    switch (event.kind) {
      case CompanionEventKind.pairingEnded:
        final waiting = _pairings.remove(event.requestId);
        if (waiting == null) return;
        unawaited(_ended(waiting, event));
    }
  }

  Future<void> _ended(
    Completer<PairedDevice> waiting,
    CompanionEventMessage event,
  ) async {
    final deviceId = event.deviceId;
    PairedDevice? device;
    try {
      device = deviceId == null ? null : await deviceById(deviceId);
    } on Object catch (error) {
      _log.warning('The paired device could not be read back: $error');
    }
    if (device != null) {
      waiting.complete(device);
    } else {
      waiting.completeError(
        PairingException(event.error ?? 'the phone did not pair'),
      );
    }
  }

  Future<void> _run(HostLifecycleFeed feed, CompanionCallMessage call) async {
    Map<String, Object?> result;
    try {
      result = await _dispatcher.run(call.method, call.arguments);
    } on RemoteApiRefusal catch (refusal) {
      feed.answerCompanionCall(
        call.callId,
        code: refusal.code.wire,
        message: refusal.message,
      );
      return;
    } on Object catch (error) {
      // A handler bug refuses one request, as the api's own catch-all does.
      _log.warning(
        'A forwarded companion call (${call.method}) failed: $error',
      );
      feed.answerCompanionCall(
        call.callId,
        code: ErrorCode.internal.wire,
        message: 'the desktop app could not handle this request',
      );
      return;
    }
    feed.answerCompanionCall(call.callId, result: result);
  }

  void _stopListening() {
    unawaited(_calls?.cancel());
    unawaited(_events?.cancel());
    _calls = null;
    _events = null;
  }

  void _failPairings(String why) {
    for (final waiting in _pairings.values) {
      if (!waiting.isCompleted) waiting.completeError(PairingException(why));
    }
    _pairings.clear();
  }
}
