import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:agent_cli/stream.dart' show isSubagentToolName;
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_session/session.dart';

/// Where a session's agent keeps its own record of the conversation, on the
/// server's machine: the file and the agent whose reader parses it.
typedef AgentRecordLocation = ({String path, String agentId});

/// How many sessions' last reading is kept. A phone reads one session at a
/// time; this is a ceiling, not a working set.
const int kAgentRecordMemoMax = 64;

/// **A session's transcript as its agent recorded it** (slice 5c) — the file
/// the agent writes in its own store (`readCliTranscript`, the reader every
/// surface uses), which the desktop used to read for a phone and the server
/// reads now, app or no app. The turns a phone is shown and the calls still
/// running (what a working agent is doing) both come off one parse.
///
/// A reading is remembered per session by the file's `(modified, size)`, so a
/// phone polling an unmoved record costs one `stat`, not a parse.
class AgentRecords {
  AgentRecords({
    Future<List<TranscriptMessage>> Function(String path, String agentId)? read,
  }) : _read = read ?? readCliTranscriptOffThread;

  final Future<List<TranscriptMessage>> Function(String path, String agentId)
  _read;
  final Map<String, _Memo> _memos = {};

  /// The turns in the record at [at] (tool rows left out, as every surface
  /// shows them), with [attribution] stripped from the user's lines, and the
  /// calls not yet answered. Null when there is no such file.
  Future<AgentRecordReading?> read(
    String sessionId,
    AgentRecordLocation at, {
    SessionAttribution? attribution,
  }) async {
    // Taken before the parse, so an append landing mid-parse is not
    // remembered as one this read served.
    final revision = await revisionOf(at.path);
    if (revision == null) return null;
    final List<TranscriptMessage> turns;
    try {
      turns = await _read(at.path, at.agentId);
    } on Object {
      return null;
    }
    final calls = outstandingCallsIn(turns);
    _remember(sessionId, _Memo(at.path, revision, calls));
    return (
      messages: [
        for (final turn in turns)
          if (turn.role != 'tool')
            RemoteTranscriptMessage(
              role: turn.role,
              text: turn.role == 'user' && attribution != null
                  ? attribution.stripFrom(turn.text)
                  : turn.text,
            ),
      ],
      calls: calls,
      revision: revision,
    );
  }

  /// Where [sessionId]'s record stands since its last read — one `stat`: null
  /// when it was never read from a record; else its file's revision now (null
  /// when the file is gone) and, only when that has not moved, the calls the
  /// last read found still running. Moved, the caller reads again.
  Future<({String? revision, List<RemoteActivityCall>? calls})?> since(
    String sessionId,
  ) async {
    final memo = _memos[sessionId];
    if (memo == null) return null;
    final revision = await revisionOf(memo.path);
    return (
      revision: revision,
      calls: revision == memo.revision ? memo.calls : null,
    );
  }

  void _remember(String sessionId, _Memo memo) {
    _memos.remove(sessionId);
    _memos[sessionId] = memo;
    while (_memos.length > kAgentRecordMemoMax) {
      _memos.remove(_memos.keys.first);
    }
  }

  /// `(modified, size)`: mtime is not distinct per write on NTFS, and an
  /// append-only record always moves its size. Null is "could not tell".
  static Future<String?> revisionOf(String path) async {
    try {
      final stat = await File(path).stat();
      if (stat.type == FileSystemEntityType.notFound) return null;
      return '${stat.modified.microsecondsSinceEpoch}:${stat.size}';
    } on Object {
      return null;
    }
  }
}

/// One read of a record: what a phone is shown, and what is still running.
typedef AgentRecordReading = ({
  List<RemoteTranscriptMessage> messages,
  List<RemoteActivityCall> calls,
  String revision,
});

/// **The calls in [turns] still running**, of both kinds (an unanswered tool
/// call, a background subagent not reported finished), at depth 1 — the
/// app's rule, moved with the reading. A line with no timestamp is dropped
/// rather than given an invented age.
List<RemoteActivityCall> outstandingCallsIn(List<TranscriptMessage> turns) => [
  for (final turn in turns)
    if (turn.tool case final tool?)
      if (turn.at case final startedAt?)
        if (turn.pendingToolUseId != null ||
            turn.pendingBackgroundAgentId != null)
          RemoteActivityCall(
            summary: tool.summary,
            toolName: tool.name,
            subagent: isSubagentToolName(tool.name),
            startedAt: startedAt,
          ),
];

/// Whether a session in [rowStatus] whose agent reads [status] is doing
/// anything a phone should be shown as running: only a working agent in a
/// session that has not ended.
bool agentIsWorking(SessionStatus rowStatus, AgentActivityStatus? status) =>
    rowStatus.claimsLive && status == AgentActivityStatus.working;

class _Memo {
  const _Memo(this.path, this.revision, this.calls);
  final String path;
  final String revision;
  final List<RemoteActivityCall> calls;
}
