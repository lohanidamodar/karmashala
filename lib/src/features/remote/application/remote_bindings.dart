/// The production wiring of [RemoteHostBindings]: every function points at
/// the SAME provider the desktop UI reads, so the phone and the screen can
/// never tell a different story about one session.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/application/agent_providers.dart';
import '../../agents/domain/agent_status.dart';
import '../../cli_detection/data/cli_transcript_reader.dart';
import '../../notifications/application/notification_providers.dart';
import '../../notifications/domain/session_attention.dart';
import '../../repositories/application/repository_providers.dart';
import '../../sessions/application/delivery_providers.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/application/session_chat_source.dart';
import '../../sessions/application/session_launcher.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_status_providers.dart';
import '../../sessions/domain/session.dart';
import '../../sessions/domain/session_attribution.dart';
import '../../sessions/domain/session_event_types.dart';
import '../../sessions/domain/session_launch.dart';
import '../domain/remote_payloads.dart';
import '../protocol.dart';
import 'host_bindings.dart';
import 'remote_providers.dart';

/// The delivery-stage lookup, split out so tests can stub the one binding
/// whose production path costs a git/gh probe (`sessionDeliveryProvider` —
/// the same probe the desktop strip pays for a session on screen).
final remoteDeliveryStageProvider =
    Provider<Future<String?> Function(String sessionId)>((ref) {
      return (sessionId) async {
        try {
          final delivery = await ref.read(
            sessionDeliveryProvider(sessionId).future,
          );
          return delivery.stage.name;
        } on Object {
          return null;
        }
      };
    });

/// The Loop-49 evidence lookup, stubbed in tests for the same reason: the
/// real one reads `agentSessionStatusProvider`, whose sources include a
/// terminal grid and the CLI store on disk.
final remoteApprovalEvidenceProvider =
    Provider<Future<AgentStatusReport?> Function(String sessionId)>((ref) {
      return (sessionId) async {
        try {
          return await ref.read(agentSessionStatusProvider(sessionId).future);
        } on Object {
          return null;
        }
      };
    });

final remoteHostBindingsProvider = Provider<RemoteHostBindings>((ref) {
  RemoteSessionSnapshot snapshotOf(Session session) {
    final repository = ref
        .read(repositoryDaoProvider)
        .getById(session.repositoryId);
    return RemoteSessionSnapshot(
      sessionId: session.id,
      title: session.title,
      status: session.status.name,
      archived: session.isArchived,
      attention: _attentionFor(ref, session.id),
      repositoryId: repository?.id,
      repositoryName: repository?.name,
      createdAt: session.createdAt.toUtc().toIso8601String(),
    );
  }

  return RemoteHostBindings(
    hostName: Platform.localHostname,
    listSessions: () => [
      for (final session in ref.read(sessionDaoProvider).getAll())
        snapshotOf(session),
    ],
    sessionById: (sessionId) {
      final session = ref.read(sessionDaoProvider).getById(sessionId);
      return session == null ? null : snapshotOf(session);
    },
    deliveryStageFor: (sessionId) =>
        ref.read(remoteDeliveryStageProvider)(sessionId),
    transcriptFor: (sessionId) => _transcriptFor(ref, sessionId),
    // The composer's own route: `continueSession` types into the live PTY or
    // resumes the engine session, exactly as the desktop send button does.
    sendPrompt: (sessionId, text) =>
        ref.read(sessionActionsProvider).continueSession(sessionId, text),
    answerApproval: (sessionId, decision) =>
        _answerApproval(ref, sessionId, decision),
    approvalEvidenceFor: (sessionId) => _approvalEvidenceFor(ref, sessionId),
    registerPush: (deviceId, token, platform) async {
      ref
          .read(pairedDeviceDaoProvider)
          .updatePush(deviceId, token: token, platform: platform);
      ref.read(pairedDevicesRevisionProvider.notifier).bump();
    },
  );
});

String? _attentionFor(Ref ref, String sessionId) {
  for (final attention in ref.read(sessionAttentionProvider)) {
    if (attention.session.openId == sessionId && !attention.session.imported) {
      return attention.kind == AttentionKind.needsInput
          ? 'needs_approval'
          : 'failed';
    }
  }
  return null;
}

/// The same source selection as `SessionTranscriptView`: a PTY-hosted
/// session renders from the agent's own record; anything else renders from
/// the engine's event log. Attribution is REBUILT from the parent session's
/// typed fields and stripped on a whole-string match — never parsed out of
/// the text (the dray constraint).
Future<RemoteTranscriptPage> _transcriptFor(Ref ref, String sessionId) async {
  final session = ref.read(sessionDaoProvider).getById(sessionId);
  if (session == null) {
    throw const RemoteApiRefusal(ErrorCode.notFound, 'no such session');
  }
  var messages = session.surface == SessionSurface.pane
      ? await _agentRecordMessages(ref, session)
      : _eventLogMessages(ref, sessionId);

  final attribution = _attributionOf(ref, session);
  if (attribution != null) {
    messages = [
      for (final message in messages)
        message.role == 'user'
            ? RemoteTranscriptMessage(
                role: 'user',
                text: attribution.stripFrom(message.text),
              )
            : message,
    ];
  }
  return RemoteTranscriptPage(
    sessionId: sessionId,
    messages: messages,
    cursor: messages.length,
  );
}

/// The agent's own transcript file — `sessionChatTranscriptProvider`'s source,
/// read once rather than polled. Tool rows are dropped, as the desktop chat
/// view drops them.
Future<List<RemoteTranscriptMessage>> _agentRecordMessages(
  Ref ref,
  Session session,
) async {
  final externalId = session.externalSessionId;
  if (externalId == null || externalId.isEmpty) return const [];
  final agentId = ref
      .read(agentInstallationDaoProvider)
      .getById(session.agentInstallationId)
      ?.agentId;
  if (agentId == null) return const [];
  if (!agentSupportsChatView(ref.read(agentRegistryProvider).byId(agentId))) {
    return const [];
  }
  final path = await ref
      .read(sessionTranscriptLocatorProvider)
      .locate(agentId: agentId, externalSessionId: externalId);
  if (path == null) return const [];
  final messages = await readCliTranscript(path, agentId);
  return [
    for (final message in messages)
      if (message.role != 'tool')
        RemoteTranscriptMessage(role: message.role, text: message.text),
  ];
}

/// The engine's event log, mapped exactly as the desktop chat view maps it.
List<RemoteTranscriptMessage> _eventLogMessages(Ref ref, String sessionId) {
  final events = ref.read(sessionEventDaoProvider).listForSession(sessionId);
  final messages = <RemoteTranscriptMessage>[];
  for (final event in events) {
    switch (event.type) {
      case SessionEventTypes.userMessage:
        _addText(messages, 'user', event.payload);
      case SessionEventTypes.agentMessage:
        _addText(messages, 'agent', event.payload);
      case SessionEventTypes.error:
        _addText(messages, 'error', event.payload);
      case SessionEventTypes.sessionFailed:
        messages.add(
          const RemoteTranscriptMessage(role: 'error', text: 'Session failed.'),
        );
      case SessionEventTypes.sessionCancelled:
        messages.add(
          const RemoteTranscriptMessage(role: 'tool', text: 'Session ended.'),
        );
    }
  }
  return messages;
}

void _addText(List<RemoteTranscriptMessage> out, String role, String payload) {
  String text = '';
  try {
    final decoded = jsonDecode(payload);
    if (decoded is Map<String, dynamic>) {
      text = (decoded['text'] ?? '').toString();
    }
  } on FormatException {
    // Not JSON; nothing to show.
  }
  if (text.isNotEmpty) out.add(RemoteTranscriptMessage(role: role, text: text));
}

SessionAttribution? _attributionOf(Ref ref, Session session) {
  final parentId = session.parentSessionId;
  if (parentId == null) return null;
  final parent = ref.read(sessionDaoProvider).getById(parentId);
  if (parent == null) return null;
  return SessionAttribution(sessionId: parent.id, title: parent.title);
}

/// The Loop-49 answer path: the key comes from the agent's own
/// [AgentApprovalRules] and is pressed by [SessionLauncher.answerPrompt] —
/// nothing here invents a binding.
Future<String> _answerApproval(
  Ref ref,
  String sessionId,
  String decision,
) async {
  final session = ref.read(sessionDaoProvider).getById(sessionId);
  if (session == null) {
    throw const RemoteApiRefusal(ErrorCode.notFound, 'no such session');
  }
  final agentId = ref
      .read(agentInstallationDaoProvider)
      .getById(session.agentInstallationId)
      ?.agentId;
  final rules = agentId == null
      ? const AgentApprovalRules()
      : ref.read(agentRegistryProvider).byId(agentId)?.approval ??
            const AgentApprovalRules();
  final key = decision == 'approve' ? rules.approve : rules.deny;
  if (key == null) {
    throw RemoteApiRefusal(
      ErrorCode.badRequest,
      'this agent names no way to $decision from outside its terminal',
    );
  }
  if (!ref.read(sessionLauncherProvider).answerPrompt(sessionId, key.keys)) {
    throw const RemoteApiRefusal(
      ErrorCode.notFound,
      'this session has no live terminal to answer in',
    );
  }
  return key.label;
}

Future<RemoteApprovalRequest> _approvalEvidenceFor(
  Ref ref,
  String sessionId,
) async {
  final session = ref.read(sessionDaoProvider).getById(sessionId);
  final agentId = session == null
      ? null
      : ref
            .read(agentInstallationDaoProvider)
            .getById(session.agentInstallationId)
            ?.agentId;
  final rules = agentId == null
      ? null
      : ref.read(agentRegistryProvider).byId(agentId)?.approval;
  final report = await ref.read(remoteApprovalEvidenceProvider)(sessionId);
  return RemoteApprovalRequest(
    sessionId: sessionId,
    evidence: report?.status == AgentActivityStatus.awaitingApproval
        ? report!.evidence
        : const [],
    approveLabel: rules?.approve?.label,
    denyLabel: rules?.deny?.label,
  );
}
