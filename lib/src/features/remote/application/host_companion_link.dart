/// This app's half of the phone companion when the session host serves it:
/// it answers the calls the host forwards, and carries the Remote access
/// settings, the desktop's news and pairing requests the other way.
library;

import 'dart:async';

import 'package:karmashala_companion_server/karmashala_companion_server.dart';
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
    required this.onDevicesChanged,
    AppLogger? logger,
  }) : _dispatcher = CompanionCallDispatcher(bindings),
       _log = logger ?? AppLogger.named('remote.host');

  final CompanionCallDispatcher _dispatcher;

  /// The row a pairing stored, read back once the host says it paired.
  final PairedDevice? Function(String deviceId) deviceById;

  /// The host moved paired-device rows: lists re-read.
  final void Function() onDevicesChanged;

  final AppLogger _log;

  HostLifecycleFeed? _feed;
  StreamSubscription<CompanionCallMessage>? _calls;
  StreamSubscription<CompanionEventMessage>? _events;
  Map<String, Object?>? _config;
  final Map<int, Completer<PairedDevice>> _pairings = {};

  /// Whether a link to the host is open, so pairing can be asked for.
  bool get connected => _feed != null;

  @override
  void attached(HostLifecycleFeed feed) {
    _stopListening();
    _feed = feed;
    _calls = feed.companionCalls.listen((call) => unawaited(_run(feed, call)));
    _events = feed.companionEvents.listen(_onEvent);
    final config = _config;
    // Every link, not just the first: the host may be a new one.
    if (config != null) feed.configureCompanion(config);
  }

  @override
  void detached() {
    _stopListening();
    _feed = null;
    _failPairings('the session host went away before a phone paired');
  }

  /// Serves phones by [config] from now on — sent at once when a link is
  /// open, and on every link after.
  void configure(CompanionConfig config) {
    final json = config.toJson();
    _config = json;
    _feed?.configureCompanion(json);
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
      case CompanionEventKind.devicesChanged:
        onDevicesChanged();
      case CompanionEventKind.pairingEnded:
        final waiting = _pairings.remove(event.requestId);
        if (waiting == null) return;
        onDevicesChanged();
        final deviceId = event.deviceId;
        final device = deviceId == null ? null : deviceById(deviceId);
        if (device != null) {
          waiting.complete(device);
        } else {
          waiting.completeError(
            PairingException(event.error ?? 'the phone did not pair'),
          );
        }
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
