/// One read of a session's record, and the two answers it carries: the page and
/// what is still in flight. The largest transcript here is 53 MB.
library;

import 'dart:convert';

import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/read.dart';
import '../../sessions/application/session_activity_providers.dart';
import '../../sessions/application/session_chat_source.dart';
import '../../sessions/application/session_chat_view_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_status_providers.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/transcript.dart';
import 'package:karmashala_session/launch.dart';
import 'package:agent_cli/stream.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/host.dart';
import 'remote_binding_support.dart';

/// The same source selection as `SessionTranscriptView`. Attribution is REBUILT
/// from the parent's typed fields, never parsed out of the text.
Future<RemoteSessionRecord> remoteTranscriptFor(
  Ref ref,
  String sessionId,
) async {
  final resolved = resolveRemoteSession(ref, sessionId);
  final session = resolved.native;
  if (session == null) {
    final imported = resolved.imported;
    if (imported != null) {
      // Imported history is not a running session: it has no row to be
      // `working`, so the one rule answers "nothing is running" for it.
      return (
        page: await _importedTranscript(imported),
        activity: _activityOf(ref, sessionId, SessionActivity.none),
      );
    }
    throw const RemoteApiRefusal(ErrorCode.notFound, 'no such session');
  }
  final record = session.surface == SessionSurface.pane
      ? await _agentRecordMessages(ref, session)
      // `session.id`, not the id asked with: a superseded imported id has no
      // event log of its own.
      : (
          messages: _eventLogMessages(ref, session.id),
          absence: null,
          turns: null,
        );
  var messages = record.messages;

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
  return (
    page: RemoteTranscriptPage(
      // The row this actually came from: a phone that asked with a superseded
      // imported id learns the live one here.
      sessionId: session.id,
      messages: messages,
      cursor: messages.length,
      // Only ever a reason for a nothing. A page that carries turns needs no
      // explanation, and one that carried both would be saying two things.
      absence: messages.isEmpty ? record.absence : null,
    ),
    activity: _activityOf(
      ref,
      session.id,
      sessionActivityFrom(
        rowStatus: session.status,
        surface: session.surface,
        // The registry's cached answer, read synchronously: the same word the
        // desktop badge shows, and no poll of its own.
        status: ref.read(sessionActivityLookupProvider)(session.id),
        messages: record.turns,
      ),
    ),
  );
}

/// The wire form of one [SessionActivity], stamped with the host's clock and
/// said out loud, so both ends agree on an elapsed time.
RemoteSessionActivity _activityOf(
  Ref ref,
  String sessionId,
  SessionActivity activity,
) => RemoteSessionActivity(
  sessionId: sessionId,
  observedAt: ref.read(clockProvider).nowUtc(),
  calls: [
    for (final call in activity.calls)
      RemoteActivityCall(
        summary: call.summary,
        toolName: call.toolName,
        subagent: call.isSubagent,
        startedAt: call.startedAt,
      ),
  ],
  absence: switch (activity.blindSpot) {
    ActivityBlindSpot.noRecord => RemoteActivityAbsence.noRecord,
    null => null,
  },
);

/// An imported CLI session's transcript, exactly what the desktop's imported
/// view reads. No attribution — an imported session has no parent of ours.
Future<RemoteTranscriptPage> _importedTranscript(
  ImportedSession session,
) async {
  final messages = await readCliTranscriptOffThread(
    session.filePath,
    session.cli,
  );
  final mapped = [
    for (final message in messages)
      if (message.role != 'tool')
        RemoteTranscriptMessage(role: message.role, text: message.text),
  ];
  return RemoteTranscriptPage(
    sessionId: session.id,
    messages: mapped,
    cursor: mapped.length,
  );
}

/// What [_agentRecordMessages] answers with: the turns, and *why* there are
/// none when the host can say so.
typedef _AgentRecord = ({
  List<RemoteTranscriptMessage> messages,
  RemoteTranscriptAbsence? absence,

  /// The parse the [messages] were cut from, so activity is read off the same
  /// read. **Null means there was no record** — not "nothing is outstanding".
  List<TranscriptMessage>? turns,
});

const _AgentRecord _nothingKnown = (
  messages: <RemoteTranscriptMessage>[],
  absence: null,
  turns: null,
);

/// A structural nothing, in the wire's own words — which of the two the reading
/// found, so the phone can say the one that is true of this session.
_AgentRecord _structuralNothing(SessionChatView reading) => (
  messages: const <RemoteTranscriptMessage>[],
  absence: reading.evidence == ChatViewEvidence.transcriptAbsent
      ? RemoteTranscriptAbsence.noTranscriptFile
      : RemoteTranscriptAbsence.noChatView,
  turns: null,
);

/// The agent's own transcript file, read once, not polled. A **structural**
/// nothing still holds after the agent answers; other empties do not.
Future<_AgentRecord> _agentRecordMessages(Ref ref, Session session) async {
  final screen = screenSessionChatView(ref, session.id);
  if (screen.keepsNoRecord) return _structuralNothing(screen);
  final externalId = session.externalSessionId;
  if (externalId == null || externalId.isEmpty) return _nothingKnown;
  final agentId = ref
      .read(agentInstallationDaoProvider)
      .getById(session.agentInstallationId)
      ?.agentId;
  if (agentId == null) return _nothingKnown;
  final path = await ref
      .read(sessionTranscriptLocatorProvider)
      .locate(agentId: agentId, externalSessionId: externalId);
  final chatView = await readChatViewAt(
    storePath: path,
    agentId: agentId,
    prior: screen.prior,
    at: ref.read(clockProvider).nowUtc(),
  );
  if (chatView.keepsNoRecord) return _structuralNothing(chatView);
  if (path == null || !chatView.hasChatView) return _nothingKnown;
  final messages = await readCliTranscriptOffThread(path, agentId);
  return (
    messages: [
      for (final message in messages)
        if (message.role != 'tool')
          RemoteTranscriptMessage(role: message.role, text: message.text),
    ],
    absence: null,
    turns: messages,
  );
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
