import 'dart:async';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_host/lifecycle_client.dart'
    show AutomationCallMessage, AutomationNoticeKind, ChecksRanMessage;

import '../../sessions/application/host_lifecycle/host_lifecycle_source.dart';
import '../../sessions/application/host_lifecycle/host_lifecycle_subscriber.dart';

/// This app's half of the automations the server runs: it says it is the app
/// on every link and runs what the server forwards. What either writes
/// reaches the other on the data link.
class HostAutomationsLink implements HostLinkPeer {
  HostAutomationsLink({required this.onCall, AppLogger? logger})
    : _log = logger ?? AppLogger.named('automations.host');

  /// Runs one forwarded call; throws to fail it with the error's words.
  final Future<void> Function(AutomationCallMessage call) onCall;

  final AppLogger _log;
  HostLifecycleFeed? _feed;
  StreamSubscription<AutomationCallMessage>? _calls;

  bool get connected => _feed != null;

  @override
  void attached(HostLifecycleFeed feed) {
    _stopListening();
    _feed = feed;
    _calls = feed.automationCalls.listen((call) => unawaited(_run(feed, call)));
    // Every link: the server may be a new one, and it waits for an app.
    feed.noticeAutomations(AutomationNoticeKind.ready);
  }

  @override
  void detached() {
    _stopListening();
    _feed = null;
  }

  /// Runs [sessionId]'s checks at the server, or null with no link open.
  Future<ChecksRanMessage>? runChecks(String sessionId) =>
      _feed?.runChecks(sessionId);

  Future<void> _run(HostLifecycleFeed feed, AutomationCallMessage call) async {
    try {
      await onCall(call);
      feed.answerAutomationCall(call.callId);
    } on Object catch (error) {
      _log.warning('automations: a forwarded ${call.kind.name} failed: $error');
      feed.answerAutomationCall(call.callId, error: '$error');
    }
  }

  void _stopListening() {
    unawaited(_calls?.cancel());
    _calls = null;
  }
}
