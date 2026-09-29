import 'dart:convert';
import 'dart:io';

import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_host/lifecycle_client.dart' as wire;
import 'package:karmashala_host_protocol/host_access.dart'
    show HostSessionAccess;
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_terminal_runtime/host_link.dart'
    show SharedHostLinks;

import 'host_lifecycle_source.dart';
import 'relayed_agent_hook.dart';

/// The lifecycle feed of the server this window is a client of — this
/// machine's or one elsewhere — on the one link its panes and data share.
class ServerLifecycleSource implements HostLifecycleSource {
  const ServerLifecycleSource(this.access);

  final HostSessionAccess access;

  @override
  Future<HostLifecycleFeed?> open({List<String> runByClient = const []}) async {
    final wire.HostLifecycleWatch watch;
    try {
      watch = await wire.HostLifecycleWatch.onLink(
        await SharedHostLinks.linkTo(access),
        runByClient: runByClient,
      );
    } on SocketException {
      return null;
    }
    final observedAt = watch.snapshotObservedAt.toUtc();
    return HostLifecycleFeed(
      snapshot: [
        for (final session in watch.snapshot) _factsOf(session, observedAt),
      ],
      events: watch.events.map(_eventOf),
      close: watch.close,
      hookSnapshot: [for (final hook in watch.hookSnapshot) _hookOf(hook)],
      hooks: watch.hooks.map(_hookOf),
      companionEvents: watch.companionEvents,
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
      answerPrompt: (request) async {
        final wire.PromptAnsweredMessage reply;
        try {
          reply = await watch.answerPrompt(request.toJson());
        } on wire.HostLifecycleWatchRefused catch (error) {
          // Sent, and no reply: the frame may still land, so this cannot say
          // nothing was pressed. The prompt on screen says whether it was.
          throw SessionPromptRefusal(
            error.timedOut
                ? 'Not confirmed — check the session'
                : 'Not confirmed — check the session (${error.message})',
            unconfirmed: true,
          );
        }
        return _answerOf(reply);
      },
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
      // Known by its words: a refusal kind of its own would be one an older
      // client could not read.
      stale: reply.message == kPromptChangedRefusal,
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
