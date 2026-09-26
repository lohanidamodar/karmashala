import 'dart:async';

import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_remote/host.dart';
import 'package:karmashala_remote/remote.dart';

import '../protocol/messages.dart';

/// Companion calls the host forwards to the connected desktop app: the one
/// connection that last sent its companion config, and the calls in flight.
/// Like the MCP relay, nothing is timed out here — an approval answered by
/// pressing keys takes as long as the app's own pacing does.
class CompanionAppRelay implements CompanionAppLink {
  _AppLink? _app;
  final _pending = <int, _PendingCall>{};
  var _lastCallId = 0;

  /// Told when the app arrives or leaves, so what the phones see is re-read.
  void Function(bool connected)? onChanged;

  @override
  bool get connected => _app != null;

  /// Whether [owner] is the app calls go to.
  bool isApp(Object owner) => identical(_app?.owner, owner);

  /// [owner] answers companion calls from now on; frames go through [send].
  void adopt(Object owner, void Function(HostMessage) send) {
    final previous = _app;
    _app = _AppLink(owner, send);
    if (previous != null && !identical(previous.owner, owner)) {
      _failCallsOf(previous.owner, 'the Karmashala app was replaced');
    }
    if (previous == null) onChanged?.call(true);
  }

  /// [owner]'s answer to one call; ignored when nothing waits for it.
  void answer(Object owner, CompanionResultMessage result) {
    final pending = _pending[result.callId];
    if (pending == null || !identical(pending.owner, owner)) return;
    _pending.remove(result.callId);
    if (result.ok) {
      pending.done.complete(result.result ?? const {});
    } else {
      pending.done.completeError(
        RemoteApiRefusal(
          ErrorCode.tryParse(result.code!) ?? ErrorCode.internal,
          result.message!,
        ),
      );
    }
  }

  /// [owner] hung up: its calls fail and nothing more goes to it.
  void detach(Object owner) {
    final wasApp = isApp(owner);
    if (wasApp) _app = null;
    _failCallsOf(
      owner,
      'the Karmashala app closed before it answered; ask again',
    );
    if (wasApp) onChanged?.call(false);
  }

  @override
  Future<Map<String, Object?>> call(
    CompanionMethod method,
    Map<String, Object?> arguments,
  ) {
    final app = _app;
    if (app == null) return Future.error(companionAppNotRunning);
    final callId = ++_lastCallId;
    final done = Completer<Map<String, Object?>>();
    _pending[callId] = _PendingCall(app.owner, done);
    app.send(
      CompanionCallMessage(
        callId: callId,
        method: method.wire,
        arguments: arguments,
      ),
    );
    return done.future;
  }

  /// Fails every call in flight: the host is stopping.
  void close() {
    for (final pending in _pending.values) {
      pending.done.completeError(
        const RemoteApiRefusal(
          ErrorCode.internal,
          'the session host is stopping',
        ),
      );
    }
    _pending.clear();
    _app = null;
  }

  void _failCallsOf(Object owner, String why) {
    for (final entry in _pending.entries.toList()) {
      if (!identical(entry.value.owner, owner)) continue;
      _pending.remove(entry.key);
      entry.value.done.completeError(RemoteApiRefusal(ErrorCode.internal, why));
    }
  }
}

class _AppLink {
  _AppLink(this.owner, this.send);
  final Object owner;
  final void Function(HostMessage) send;
}

class _PendingCall {
  _PendingCall(this.owner, this.done);
  final Object owner;
  final Completer<Map<String, Object?>> done;
}
