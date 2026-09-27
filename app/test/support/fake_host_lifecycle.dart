import 'dart:async';

import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_source.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/relayed_agent_hook.dart';
import 'package:karmashala_host/lifecycle_client.dart'
    show
        CompanionCallMessage,
        CompanionEventMessage,
        CompanionNoticeMessage,
        PairedMessage;
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';

import 'fake_data_server.dart';
import 'fixtures.dart';

/// A host that answers from memory: each [open] is one link, whose events the
/// test pushes and whose end is the host going away.
///
/// Given a [server], it is also the daemon writing to it, as `serve` does:
/// the snapshot and the unheld rows on each open, then each event — every
/// write told to the app on the data channel, as the server's own change.
/// Without one it writes nothing. A row runs on this machine unless its
/// checkout (or directory) is on an SSH environment (`ssh:…`), or
/// [runsOnThisMachine] says otherwise.
class FakeHostLifecycle implements HostLifecycleSource {
  FakeHostLifecycle([
    FakeDataServer? server,
    bool Function(Session session)? runsOnThisMachine,
  ]) : _keeper = server == null
           ? null
           : HostedSessionStatusKeeper(
               server.sessionRows,
               runsOnThisMachine:
                   runsOnThisMachine ?? (s) => _notSsh(server, s),
             );

  static bool _notSsh(FakeDataServer server, Session session) {
    final environment =
        session.workingDirectory?.environmentId ??
        server.repositoryRows.getById(session.repositoryId)?.path.environmentId;
    return environment != null && !environment.startsWith('ssh');
  }

  final HostedSessionStatusKeeper? _keeper;
  bool listening = true;
  List<SessionFacts> snapshot = const [];
  List<RelayedAgentHook> hookSnapshot = const [];
  final links = <StreamController<SessionLifecycleEvent>>[];
  final hookLinks = <StreamController<RelayedAgentHook>>[];

  /// What the host says each agent it holds is doing, sent on each open.
  List<HostedAgentStatus> statusSnapshot = const [];

  /// Each link's agent status frames, pushed by the test as the daemon.
  final statusLinks = <StreamController<HostAgentStatusChange>>[];
  StreamController<HostAgentStatusChange> get statusLink => statusLinks.last;

  /// The prompt answers the app asked the host for, in order, and how the
  /// host answers them.
  final promptRequests = <PromptAnswerRequest>[];
  Future<SessionApprovalAnswer> Function(PromptAnswerRequest request)
  answerPrompt = (request) async =>
      const SessionApprovalAnswer(answered: 'Yes', effect: 'by the host');

  /// What each open said the app runs itself.
  final runByClient = <List<String>>[];

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

  /// Each attach the app sent, in order: where its embedded relay was.
  final companionAttaches = <String?>[];

  /// The server calls the app made, in order, and how they are answered —
  /// refused when nobody set [answerServerCall].
  final serverCalls = <({String method, Map<String, Object?> arguments})>[];
  Future<Map<String, Object?>> Function(
    String method,
    Map<String, Object?> arguments,
  )?
  answerServerCall;

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

  @override
  Future<HostLifecycleFeed?> open({List<String> runByClient = const []}) async {
    this.runByClient.add(runByClient);
    // Answered later, as a socket is: the daemon's writes below then reach a
    // client outside whatever provider build dialled.
    await Future<void>.value();
    if (!listening) return null;
    final link = StreamController<SessionLifecycleEvent>();
    final hooks = StreamController<RelayedAgentHook>();
    final calls = StreamController<HostMcpCall>();
    mcpCallLinks.add(calls);
    final companionCalls = StreamController<CompanionCallMessage>();
    final companionEvents = StreamController<CompanionEventMessage>();
    companionCallLinks.add(companionCalls);
    companionEventLinks.add(companionEvents);
    final statuses = StreamController<HostAgentStatusChange>();
    statusLinks.add(statuses);
    links.add(link);
    hookLinks.add(hooks);
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
      mcpCalls: calls.stream,
      offerMcpTools: offeredTools.add,
      answerMcpCall: (callId, {result, error}) =>
          mcpAnswers.add((callId: callId, result: result, error: error)),
      companionCalls: companionCalls.stream,
      companionEvents: companionEvents.stream,
      attachCompanion: ({localRelayUrl}) =>
          companionAttaches.add(localRelayUrl),
      serverCall: (method, [arguments = const {}]) {
        serverCalls.add((method: method, arguments: arguments));
        final answer = answerServerCall;
        if (answer == null) {
          return Future.error(StateError('no server calls here'));
        }
        return answer(method, arguments);
      },
      answerCompanionCall: (callId, {result, code, message}) => companionAnswers
          .add((callId: callId, result: result, code: code, message: message)),
      noticeCompanion: companionNotices.add,
      statusSnapshot: List.of(statusSnapshot),
      agentStatuses: statuses.stream,
      answerPrompt: (request) {
        promptRequests.add(request);
        return answerPrompt(request);
      },
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
        if (!statuses.isClosed) unawaited(statuses.close());
        if (!link.isClosed) await link.close();
        if (!hooks.isClosed) await hooks.close();
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
