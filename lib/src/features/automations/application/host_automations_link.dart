import 'dart:async';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_host/lifecycle_client.dart'
    show AutomationCallMessage, AutomationNoticeKind, ChecksRanMessage;

import '../../sessions/application/host_lifecycle/host_lifecycle_source.dart';
import '../../sessions/application/host_lifecycle/host_lifecycle_subscriber.dart';

/// This app's half of the automations the session host runs: it says it is
/// the app on every link, runs what the host forwards, hears when the host
/// wrote rows, and tells it when this app did.
class HostAutomationsLink implements HostLinkPeer {
  HostAutomationsLink({
    required this.onCall,
    required this.onHostChanged,
    AppLogger? logger,
  }) : _log = logger ?? AppLogger.named('automations.host');

  /// Runs one forwarded call; throws to fail it with the error's words.
  final Future<void> Function(AutomationCallMessage call) onCall;

  /// The host wrote automation, run, check, resume or verification rows.
  final void Function() onHostChanged;

  final AppLogger _log;
  HostLifecycleFeed? _feed;
  StreamSubscription<AutomationCallMessage>? _calls;
  StreamSubscription<void>? _changes;

  bool get connected => _feed != null;

  @override
  void attached(HostLifecycleFeed feed) {
    _stopListening();
    _feed = feed;
    _calls = feed.automationCalls.listen((call) => unawaited(_run(feed, call)));
    _changes = feed.automationsChanged.listen((_) => onHostChanged());
    // Every link: the host may be a new one, and it waits for an app.
    feed.noticeAutomations(AutomationNoticeKind.ready);
    // Whatever the host wrote while no link was open.
    onHostChanged();
  }

  @override
  void detached() {
    _stopListening();
    _feed = null;
  }

  /// This app wrote automation rows; the host re-reads and re-arms. Nothing
  /// while no link is open: the host reads the store when it starts.
  void notifyChanged() =>
      _feed?.noticeAutomations(AutomationNoticeKind.changed);

  /// Runs [sessionId]'s checks at the host, or null with no link open.
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
    unawaited(_changes?.cancel());
    _calls = null;
    _changes = null;
  }
}
