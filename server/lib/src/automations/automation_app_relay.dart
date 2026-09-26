import 'dart:async';

import '../protocol/messages.dart';

/// What a forwarded automation call is failed with when no app is connected.
const String kAutomationAppNotRunning = 'the Karmashala app is not running';

/// A forwarded automation call that failed: no app, or the app said why.
class AutomationRelayFailure implements Exception {
  const AutomationRelayFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Automation calls the host forwards to the connected app: the one
/// connection that last said it is the app, and the calls in flight. Nothing
/// is timed out — a resume waits for its agent as long as the app does.
class AutomationAppRelay {
  _AppLink? _app;
  final _pending = <int, _PendingCall>{};
  var _lastCallId = 0;

  /// Told when an app arrives, so what waited for one is looked at again.
  void Function()? onConnected;

  bool get connected => _app != null;

  /// [owner] is the app from now on; frames to it go through [send].
  void adopt(Object owner, void Function(HostMessage) send) {
    final previous = _app;
    _app = _AppLink(owner, send);
    if (previous != null && !identical(previous.owner, owner)) {
      _failCallsOf(previous.owner, 'the Karmashala app was replaced');
    }
    if (previous == null || !identical(previous.owner, owner)) {
      onConnected?.call();
    }
  }

  /// [owner]'s answer to one call; ignored when nothing waits for it.
  void answer(Object owner, AutomationResultMessage result) {
    final pending = _pending[result.callId];
    if (pending == null || !identical(pending.owner, owner)) return;
    _pending.remove(result.callId);
    if (result.ok) {
      pending.done.complete();
    } else {
      pending.done.completeError(AutomationRelayFailure(result.message!));
    }
  }

  /// [owner] hung up: its calls fail and nothing more goes to it.
  void detach(Object owner) {
    if (identical(_app?.owner, owner)) _app = null;
    _failCallsOf(owner, 'the Karmashala app closed before it answered');
  }

  /// Asks the app to do [kind] for [id]. Throws [AutomationRelayFailure] when
  /// no app is connected or it failed.
  Future<void> call(
    AutomationCallKind kind,
    String id, {
    String note = '',
    DateTime? scheduledFor,
    String? queuedRunId,
  }) {
    final app = _app;
    if (app == null) {
      return Future.error(
        const AutomationRelayFailure(kAutomationAppNotRunning),
      );
    }
    final callId = ++_lastCallId;
    final done = Completer<void>();
    _pending[callId] = _PendingCall(app.owner, done);
    app.send(
      AutomationCallMessage(
        callId: callId,
        kind: kind,
        id: id,
        note: note,
        scheduledFor: scheduledFor,
        queuedRunId: queuedRunId,
      ),
    );
    return done.future;
  }

  /// Fails every call in flight: the host is stopping.
  void close() {
    for (final pending in _pending.values) {
      pending.done.completeError(
        const AutomationRelayFailure('the session host is stopping'),
      );
    }
    _pending.clear();
    _app = null;
  }

  void _failCallsOf(Object owner, String why) {
    for (final entry in _pending.entries.toList()) {
      if (!identical(entry.value.owner, owner)) continue;
      _pending.remove(entry.key);
      entry.value.done.completeError(AutomationRelayFailure(why));
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
  final Completer<void> done;
}
