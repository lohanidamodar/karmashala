import 'dart:convert';

import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_host/lifecycle_client.dart' as wire;
import 'package:karmashala_session_engine/karmashala_session_engine.dart';

import 'host_lifecycle_source.dart';
import 'relayed_agent_hook.dart';

/// The lifecycle feed of the session host on this machine, over its socket.
class LocalHostLifecycleSource implements HostLifecycleSource {
  const LocalHostLifecycleSource(this.socketPath);

  final String socketPath;

  @override
  Future<HostLifecycleFeed?> open({List<String> runByClient = const []}) async {
    final watch = await wire.HostLifecycleWatch.connect(
      socketPath,
      runByClient: runByClient,
    );
    if (watch == null) return null;
    final observedAt = watch.snapshotObservedAt.toUtc();
    return HostLifecycleFeed(
      snapshot: [
        for (final session in watch.snapshot) _factsOf(session, observedAt),
      ],
      events: watch.events.map(_eventOf),
      close: watch.close,
      hookSnapshot: [for (final hook in watch.hookSnapshot) _hookOf(hook)],
      hooks: watch.hooks.map(_hookOf),
      mcpCalls: watch.mcpCalls.map(
        (call) => (
          callId: call.callId,
          tool: call.tool,
          arguments: call.arguments.cast<String, dynamic>(),
          callerSessionId: call.callerSessionId,
        ),
      ),
      offerMcpTools: watch.offerMcpTools,
      answerMcpCall: watch.answerMcpCall,
      companionEvents: watch.companionEvents,
      attachCompanion: watch.attachCompanion,
      serverCall: watch.serverCall,
      noticeCompanion: watch.noticeCompanion,
      pairCompanion: watch.pairCompanion,
      statusSnapshot: [
        for (final json in watch.statusSnapshot)
          ?HostedAgentStatus.fromJson(json),
      ],
      agentStatuses: watch.agentStatuses.map(
        (message) => (
          sessionId: message.sessionId,
          status: HostedAgentStatus.fromJson(message.status),
        ),
      ),
      answerPrompt: (request) async =>
          _answerOf(await watch.answerPrompt(request.toJson())),
    );
  }

  /// The host's reply as the answer it reports, or the refusal it gave.
  static SessionApprovalAnswer _answerOf(wire.PromptAnsweredMessage reply) {
    if (reply.ok) {
      return SessionApprovalAnswer(
        answered: reply.answered ?? '',
        effect: reply.effect ?? '',
      );
    }
    throw SessionPromptRefusal(
      reply.message ?? 'the session host did not answer it',
      notFound: reply.refusal == wire.PromptRefusalKind.notFound,
      noTerminal: reply.refusal == wire.PromptRefusalKind.noTerminal,
    );
  }

  static RelayedAgentHook _hookOf(wire.AgentHookEvent hook) => RelayedAgentHook(
    agentId: hook.agent,
    event: hook.event,
    body: jsonEncode(hook.body),
    receivedAt: hook.receivedAt.toUtc(),
    paneSessionId: hook.sessionHeader,
  );

  static SessionFacts _factsOf(
    wire.HostSessionFacts session,
    DateTime observedAt,
  ) => SessionFacts(
    hostSessionId: session.sessionId,
    state: switch (session.state) {
      wire.HostSessionState.running => HostSessionState.running,
      wire.HostSessionState.exited => HostSessionState.exited,
      wire.HostSessionState.closed => HostSessionState.closed,
    },
    exitCode: session.exitCode,
    reason: session.reason,
    endedByClose: session.endedByClose,
    observedAt: observedAt,
  );

  static SessionLifecycleEvent _eventOf(wire.LifecycleEvent event) =>
      SessionLifecycleEvent(
        hostSessionId: event.sessionId,
        kind: switch (event.kind) {
          wire.LifecycleEventKind.started => SessionLifecycleKind.started,
          wire.LifecycleEventKind.exited => SessionLifecycleKind.exited,
          wire.LifecycleEventKind.closed => SessionLifecycleKind.closed,
        },
        exitCode: event.exitCode,
        reason: event.reason,
        endedByClose: event.endedByClose,
        observedAt: event.observedAt.toUtc(),
      );
}
