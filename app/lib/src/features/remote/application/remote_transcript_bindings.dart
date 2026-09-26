/// One read of a session's record, and the two answers it carries: the page and
/// what is still in flight. The largest transcript here is 53 MB.
library;

import 'dart:convert';
import 'dart:io';

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

/// How many sessions' record memos are kept. A phone reads one session at a
/// time and the entries are tiny, so this is a ceiling, not a working set.
const int kRemoteRecordMemoMax = 64;

/// What the last read of one session's record found, so the next poll can tell
/// a file that has not moved from one that has — and answer for it — with a
/// `stat` instead of a parse.
///
/// **The turns are not kept.** Only the calls they implied: the unanswered
/// ones of one session, three small fields each. Keeping the parse instead
/// would trade the poll's CPU for the memory this app is already growing.
class _RecordMemo {
  const _RecordMemo({
    required this.path,
    required this.revision,
    required this.calls,
    required this.native,
  });

  final String path;
  final String revision;
  final List<OutstandingCall> calls;

  /// Which branch read it. A superseded imported id can start resolving to a
  /// live row, and the two answer the activity question differently.
  final bool native;
}

/// One memo per session, oldest dropped past [kRemoteRecordMemoMax].
class _RecordMemos {
  final Map<String, _RecordMemo> _bySession = <String, _RecordMemo>{};

  _RecordMemo? read(String sessionId) => _bySession[sessionId];

  void write(String sessionId, _RecordMemo memo) {
    // Re-inserted so insertion order is recency, which is what the cap drops.
    _bySession.remove(sessionId);
    _bySession[sessionId] = memo;
    while (_bySession.length > kRemoteRecordMemoMax) {
      _bySession.remove(_bySession.keys.first);
    }
  }
}

final _recordMemosProvider = Provider<_RecordMemos>((ref) => _RecordMemos());

/// `(modified, size)`, for the same reason the desktop chat view uses it:
/// mtime is not distinct per write on NTFS, and an append-only transcript
/// always moves its size. Null is "could not tell", never "unchanged".
Future<String?> _revisionOf(String path) async {
  try {
    final stat = await File(path).stat();
    if (stat.type == FileSystemEntityType.notFound) return null;
    return '${stat.modified.microsecondsSinceEpoch}:${stat.size}';
  } on Object {
    return null;
  }
}

/// Whether a session's record has moved since this host last read it, and what
/// it is doing if it has not — **one `stat`**, no store scan and no parse.
///
/// Answers `activity: null` for anything it cannot speak for without reading:
/// a session never read here, a file that moved, or one that is gone.
Future<RemoteRecordReading> remoteRecordReading(
  Ref ref,
  String sessionId,
) async {
  final memo = ref.read(_recordMemosProvider).read(sessionId);
  if (memo == null) return (revision: null, activity: null);
  final revision = await _revisionOf(memo.path);
  if (revision == null || revision != memo.revision) {
    return (revision: revision, activity: null);
  }
  final resolved = resolveRemoteSession(ref, sessionId);
  final session = resolved.native;
  if ((session != null) != memo.native) {
    return (revision: revision, activity: null);
  }
  if (session == null) {
    if (resolved.imported == null) return (revision: null, activity: null);
    return (
      revision: revision,
      activity: _activityOf(ref, sessionId, SessionActivity.none),
    );
  }
  return (
    revision: revision,
    // The calls are the file's; the row and the status word are read fresh,
    // because those are what move while the file stands still.
    activity: _activityOf(
      ref,
      session.id,
      sessionActivityOf(
        rowStatus: session.status,
        surface: session.surface,
        status: ref.read(sessionActivityLookupProvider)(session.id),
        calls: memo.calls,
      ),
    ),
  );
}

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
      final revision = await _revisionOf(imported.filePath);
      final page = await _importedTranscript(imported);
      if (revision != null) {
        ref
            .read(_recordMemosProvider)
            .write(
              sessionId,
              _RecordMemo(
                path: imported.filePath,
                revision: revision,
                calls: const <OutstandingCall>[],
                native: false,
              ),
            );
      }
      return (
        page: page,
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
          messages: await _eventLogMessages(ref, session.id),
          absence: null,
          turns: null,
          path: null,
          revision: null,
        );
  var messages = record.messages;
  // Derived once: the memo below and the activity are the same answer.
  final turns = record.turns;
  final calls = turns == null ? null : outstandingCallsIn(turns);
  final path = record.path;
  final revision = record.revision;
  if (path != null && revision != null && calls != null) {
    // Keyed on the id the caller asked with, because that is the id the next
    // poll will ask with — a superseded imported id resolves the same way.
    ref
        .read(_recordMemosProvider)
        .write(
          sessionId,
          _RecordMemo(
            path: path,
            revision: revision,
            calls: calls,
            native: true,
          ),
        );
  }

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
      sessionActivityOf(
        rowStatus: session.status,
        surface: session.surface,
        // The registry's cached answer, read synchronously: the same word the
        // desktop badge shows, and no poll of its own.
        status: ref.read(sessionActivityLookupProvider)(session.id),
        calls: calls,
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

  /// The file [turns] were parsed from, and what it looked like **before** the
  /// parse — so a write that landed during one is not remembered as read.
  /// Null when nothing was parsed and there is nothing to remember.
  String? path,
  String? revision,
});

const _AgentRecord _nothingKnown = (
  messages: <RemoteTranscriptMessage>[],
  absence: null,
  turns: null,
  path: null,
  revision: null,
);

/// A structural nothing, in the wire's own words — which of the two the reading
/// found, so the phone can say the one that is true of this session.
_AgentRecord _structuralNothing(SessionChatView reading) => (
  messages: const <RemoteTranscriptMessage>[],
  absence: reading.evidence == ChatViewEvidence.transcriptAbsent
      ? RemoteTranscriptAbsence.noTranscriptFile
      : RemoteTranscriptAbsence.noChatView,
  turns: null,
  path: null,
  revision: null,
);

/// The agent's own transcript file, read once, not polled. A **structural**
/// nothing still holds after the agent answers; other empties do not.
Future<_AgentRecord> _agentRecordMessages(Ref ref, Session session) async {
  final screen = screenSessionChatView(ref, session.id);
  if (screen.keepsNoRecord) return _structuralNothing(screen);
  final externalId = session.externalSessionId;
  if (externalId == null || externalId.isEmpty) return _nothingKnown;
  final agentId = ref
      .read(agentInstallationsDataProvider)
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
  // Taken before the parse, so an append landing mid-parse is not remembered
  // as one this read served.
  final revision = await _revisionOf(path);
  final messages = await readCliTranscriptOffThread(path, agentId);
  return (
    messages: [
      for (final message in messages)
        if (message.role != 'tool')
          RemoteTranscriptMessage(role: message.role, text: message.text),
    ],
    absence: null,
    turns: messages,
    path: path,
    revision: revision,
  );
}

/// The engine's event log, mapped exactly as the desktop chat view maps it.
Future<List<RemoteTranscriptMessage>> _eventLogMessages(
  Ref ref,
  String sessionId,
) async {
  final events = await ref
      .read(sessionRecordsProvider)
      .listForSession(sessionId);
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
  final parent = ref.read(sessionsDataProvider).getById(parentId);
  if (parent == null) return null;
  return SessionAttribution(sessionId: parent.id, title: parent.title);
}
