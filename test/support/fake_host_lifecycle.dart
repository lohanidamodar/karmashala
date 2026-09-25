import 'dart:async';

import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_source.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/relayed_agent_hook.dart';
import 'package:karmashala_host/lifecycle_client.dart'
    show
        CompanionCallMessage,
        CompanionEventMessage,
        CompanionNoticeMessage,
        PairedMessage;
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_store/database.dart';

import 'fixtures.dart';

/// A host that answers from memory: each [open] is one link, whose events the
/// test pushes and whose end is the host going away.
///
/// Given a [store], it is also the daemon writing to it, as `serve` does: the
/// snapshot and the unheld rows on each open, then each event, every write
/// told to the app as a session change. Without one it writes nothing.
class FakeHostLifecycle implements HostLifecycleSource {
  FakeHostLifecycle([AppDatabase? store])
    : _keeper = store == null ? null : HostedSessionStatusKeeper(store) {
    _keeper?.changes.listen((change) {
      final link = changeLinks.lastOrNull;
      if (link != null && !link.isClosed) {
        link.add((sessionId: change.sessionId, status: change.to.name));
      }
    });
  }

  final HostedSessionStatusKeeper? _keeper;
  bool listening = true;
  List<SessionFacts> snapshot = const [];
  List<RelayedAgentHook> hookSnapshot = const [];
  final links = <StreamController<SessionLifecycleEvent>>[];
  final hookLinks = <StreamController<RelayedAgentHook>>[];
  final changeLinks = <StreamController<HostSessionChange>>[];

  /// What each open said the app runs itself.
  final runByClient = <List<String>>[];

  /// The hold ids the app released, in order.
  final replies = <int>[];

  /// Each link's tool calls, pushed by the test as the daemon forwarding them.
  final mcpCallLinks = <StreamController<HostMcpCall>>[];

  /// The catalogues the app offered, one per link.
  final offeredTools = <List<Map<String, Object?>>>[];

  /// How the app answered each forwarded call.
  final mcpAnswers = <({int callId, Object? result, String? error})>[];

  StreamController<HostMcpCall> get mcpCallLink => mcpCallLinks.last;

  /// Each link's companion calls and events, pushed by the test as the daemon.
  final companionCallLinks = <StreamController<CompanionCallMessage>>[];
  final companionEventLinks = <StreamController<CompanionEventMessage>>[];

  /// The companion configs the app sent, in order.
  final companionConfigs = <Map<String, Object?>>[];

  /// How the app answered each forwarded companion call.
  final companionAnswers =
      <
        ({
          int callId,
          Map<String, Object?>? result,
          String? code,
          String? message,
        })
      >[];

  /// The notices the app sent the host's companion.
  final companionNotices = <CompanionNoticeMessage>[];

  /// The pairing windows the app asked for, answered by [answerPairing].
  final pairings = <({int capabilities, String relay, bool relayIsLocal})>[];
  PairedMessage Function(int requestId)? answerPairing;

  StreamController<CompanionCallMessage> get companionCallLink =>
      companionCallLinks.last;
  StreamController<CompanionEventMessage> get companionEventLink =>
      companionEventLinks.last;

  StreamController<SessionLifecycleEvent> get link => links.last;
  StreamController<RelayedAgentHook> get hookLink => hookLinks.last;
  StreamController<HostSessionChange> get changeLink => changeLinks.last;

  @override
  Future<HostLifecycleFeed?> open({List<String> runByClient = const []}) async {
    this.runByClient.add(runByClient);
    if (!listening) return null;
    final link = StreamController<SessionLifecycleEvent>();
    final hooks = StreamController<RelayedAgentHook>();
    final changes = StreamController<HostSessionChange>();
    final calls = StreamController<HostMcpCall>();
    mcpCallLinks.add(calls);
    final companionCalls = StreamController<CompanionCallMessage>();
    final companionEvents = StreamController<CompanionEventMessage>();
    companionCallLinks.add(companionCalls);
    companionEventLinks.add(companionEvents);
    links.add(link);
    hookLinks.add(hooks);
    changeLinks.add(changes);
    final keeper = _keeper;
    if (keeper != null) {
      keeper.applySnapshot(snapshot);
      keeper.markUnheld(
        heldHostSessionIds: {for (final f in snapshot) f.hostSessionId},
        runByClient: runByClient.toSet(),
      );
    }
    return HostLifecycleFeed(
      snapshot: List.of(snapshot),
      events: link.stream.map((event) {
        keeper?.applyEvent(event);
        return event;
      }),
      hookSnapshot: List.of(hookSnapshot),
      hooks: hooks.stream,
      replyHook: replies.add,
      sessionChanges: changes.stream,
      mcpCalls: calls.stream,
      offerMcpTools: offeredTools.add,
      answerMcpCall: (callId, {result, error}) =>
          mcpAnswers.add((callId: callId, result: result, error: error)),
      companionCalls: companionCalls.stream,
      companionEvents: companionEvents.stream,
      configureCompanion: companionConfigs.add,
      answerCompanionCall: (callId, {result, code, message}) => companionAnswers
          .add((callId: callId, result: result, code: code, message: message)),
      noticeCompanion: companionNotices.add,
      pairCompanion:
          ({required capabilities, relay = '', relayIsLocal = false}) async {
            pairings.add((
              capabilities: capabilities,
              relay: relay,
              relayIsLocal: relayIsLocal,
            ));
            final answer = answerPairing;
            if (answer == null) throw StateError('no pairing here');
            return answer(pairings.length);
          },
      close: () async {
        // Not awaited: a link whose app offers no tools never listens.
        if (!calls.isClosed) unawaited(calls.close());
        if (!companionCalls.isClosed) unawaited(companionCalls.close());
        if (!companionEvents.isClosed) unawaited(companionEvents.close());
        if (!link.isClosed) await link.close();
        if (!hooks.isClosed) await hooks.close();
        if (!changes.isClosed) await changes.close();
      },
    );
  }
}

DateTime _at(int second) => testTime.add(Duration(seconds: second));

SessionFacts hostFacts(
  String sessionId,
  HostSessionState state, {
  int? exitCode,
  String? reason,
  int second = 1,
}) => SessionFacts(
  hostSessionId: hostSessionIdOf(sessionId),
  state: state,
  exitCode: exitCode,
  reason: reason,
  observedAt: _at(second),
);

SessionLifecycleEvent hostEvent(
  String sessionId,
  SessionLifecycleKind kind, {
  int? exitCode,
  String? reason,
  bool endedByClose = false,
  required int second,
}) => SessionLifecycleEvent(
  hostSessionId: hostSessionIdOf(sessionId),
  kind: kind,
  exitCode: exitCode,
  reason: reason,
  endedByClose: endedByClose,
  observedAt: _at(second),
);
