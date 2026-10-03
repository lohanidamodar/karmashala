import 'dart:io';

import 'package:agent_cli/descriptors.dart'
    show AgentActivityStatus, AgentStatusReport;
import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:agent_cli/stream.dart' show isSubagentToolName;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/lineage.dart' show SessionLink;
import 'package:karmashala_session/session.dart';

/// The most of a delegate's last answer one entry carries.
const int kSubagentResultMaxChars = 4000;

/// The last thing an agent said in [messages], or null when it has said
/// nothing — or nothing since [since], when the turn is dated.
({String text, DateTime? at})? lastAgentAnswer(
  List<TranscriptMessage> messages, {
  DateTime? since,
}) {
  for (final message in messages.reversed) {
    if (message.role != 'agent' || message.text.trim().isEmpty) continue;
    final at = message.at;
    if (since != null && at != null && at.isBefore(since)) return null;
    return (text: message.text.trim(), at: at);
  }
  return null;
}

/// [text] cut to [max] characters, and whether it was.
(String, bool) boundedText(String text, int max) =>
    text.length <= max ? (text, false) : (text.substring(0, max), true);

/// The state a session the server runs is in, by its status report: an open
/// prompt or question is [SubagentState.blocked]; a settled turn is done.
SubagentState liveSubagentState(AgentStatusReport? report) {
  if (report == null) return SubagentState.unknown;
  if (report.hasOpenPrompt || report.hasOpenQuestion) {
    return SubagentState.blocked;
  }
  return switch (report.status) {
    AgentActivityStatus.working => SubagentState.running,
    AgentActivityStatus.idle ||
    AgentActivityStatus.awaitingApproval => SubagentState.done,
    AgentActivityStatus.failed => SubagentState.failed,
    AgentActivityStatus.unknown => SubagentState.unknown,
  };
}

typedef SubagentTokens = ({int? total, SubagentTokensGap? gap});

/// **A session's delegates, gathered here** (`sessions.subagents`): the
/// subagents its agent's own record names, joined to the call that spawned
/// each, and the sessions recorded as its children. Every figure is read from
/// a record; one that is not there is left out, never estimated.
///
/// A tool call an agent spoken to over ACP makes is never listed as a
/// delegate: the protocol has no field that marks one.
class SessionSubagents {
  SessionSubagents({
    required this.messagesOf,
    required this.childrenOf,
    required this.liveStateOf,
    this.agentNameOf,
    this.sessionTokens,
    this.subagentTokens,
    this.speaksAcp,
    Future<DateTime?> Function(String path)? modifiedAt,
  }) : _modifiedAt = modifiedAt ?? _fileModified;

  /// Every row of a session's transcript, as its record holds it now.
  final Future<List<TranscriptMessage>> Function(String sessionId) messagesOf;
  final List<Session> Function(String sessionId) childrenOf;

  /// Null for a session nothing here runs.
  final SubagentState? Function(String sessionId) liveStateOf;
  final String? Function(Session session)? agentNameOf;
  final Future<SubagentTokens> Function(String sessionId)? sessionTokens;

  /// Tokens of the subagent recorded at `path`, of session `sessionId`.
  final Future<SubagentTokens> Function(String sessionId, String path)?
  subagentTokens;
  final bool Function(String sessionId)? speaksAcp;
  final Future<DateTime?> Function(String path) _modifiedAt;

  static Future<DateTime?> _fileModified(String path) async {
    try {
      final stat = await File(path).stat();
      if (stat.type == FileSystemEntityType.notFound) return null;
      return stat.modified.toUtc();
    } on Object {
      return null;
    }
  }

  Future<SessionSubagentList> read(SessionSubagentsRead request) async {
    final sessionId = request.sessionId;
    final acp = speaksAcp?.call(sessionId) ?? false;
    final entries = <SessionSubagent>[
      if (!acp) ...await _recorded(sessionId),
      for (final child in childrenOf(sessionId)) await _child(child),
    ];
    entries.sort((a, b) {
      final at = a.startedAt, bt = b.startedAt;
      if (at == null || bt == null) return 0;
      return at.compareTo(bt);
    });
    return SessionSubagentList(
      sessionId: sessionId,
      entries: entries,
      note: acp
          ? 'Tool calls this agent delegates are not listed: ACP has no way '
                'to mark one as a subagent.'
          : null,
    );
  }

  /// The subagents [sessionId]'s own record names, one per spawning call.
  Future<List<SessionSubagent>> _recorded(String sessionId) async {
    final List<TranscriptMessage> messages;
    try {
      messages = await messagesOf(sessionId);
    } on Object {
      return const [];
    }
    // A call left open by a session nothing runs any more never finished.
    final parentLive = liveStateOf(sessionId) != null;
    final out = <SessionSubagent>[];
    for (final message in messages) {
      final reference = message.subagent;
      final tool = message.tool;
      if (reference == null &&
          (tool == null || !isSubagentToolName(tool.name))) {
        continue;
      }
      final open =
          message.pendingToolUseId != null ||
          message.pendingBackgroundAgentId != null;
      final state = open
          ? (parentLive ? SubagentState.running : SubagentState.unknown)
          : (tool?.isError ?? false)
          ? SubagentState.failed
          : SubagentState.done;
      final path = reference?.filePath;
      final ended = state.isLive || path == null
          ? null
          : await _modifiedAt(path);
      final tokens = path == null
          ? (total: null, gap: SubagentTokensGap.notRecorded)
          : await (subagentTokens?.call(sessionId, path) ??
                Future.value((
                  total: null,
                  gap: SubagentTokensGap.notRecorded,
                )));
      final output = open ? null : tool?.output?.trim();
      final (result, cut) = output == null || output.isEmpty
          ? (null, false)
          : boundedText(output, kSubagentResultMaxChars);
      final description = reference?.description.trim() ?? '';
      final agentType = reference?.agentType.trim() ?? '';
      out.add(
        SessionSubagent(
          kind: SubagentKind.subagent,
          id:
              reference?.toolUseId ??
              message.pendingToolUseId ??
              '${out.length}',
          title: description.isNotEmpty
              ? description
              : (tool?.subject ?? tool?.name ?? 'Subagent'),
          state: state,
          agent: agentType.isEmpty ? null : agentType,
          model: reference?.model,
          startedAt: message.at,
          endedAt: ended,
          tokens: tokens.total,
          tokensGap: tokens.total == null
              ? (tokens.gap ?? SubagentTokensGap.notRecorded)
              : null,
          finalResult: result,
          finalResultTruncated: cut,
          transcriptPath: path,
        ),
      );
    }
    return out;
  }

  Future<SessionSubagent> _child(Session child) async {
    List<TranscriptMessage> messages;
    try {
      messages = await messagesOf(child.id);
    } on Object {
      messages = const [];
    }
    final answer = lastAgentAnswer(messages);
    final live = liveStateOf(child.id);
    final state =
        live ??
        (child.status == SessionStatus.failed
            ? SubagentState.failed
            : answer != null
            ? SubagentState.done
            : SubagentState.unknown);
    DateTime? lastAt;
    for (final message in messages.reversed) {
      if (message.at case final at?) {
        lastAt = at;
        break;
      }
    }
    final tokens =
        await sessionTokens?.call(child.id) ??
        (total: null, gap: SubagentTokensGap.notRecorded);
    final (result, cut) = answer == null
        ? (null, false)
        : boundedText(answer.text, kSubagentResultMaxChars);
    return SessionSubagent(
      kind: SubagentKind.childSession,
      id: child.id,
      title: child.title,
      state: state,
      agent: agentNameOf?.call(child),
      model: child.modelId,
      startedAt: child.createdAt,
      endedAt: state.isLive ? null : lastAt,
      tokens: tokens.total,
      tokensGap: tokens.total == null
          ? (tokens.gap ?? SubagentTokensGap.notRecorded)
          : null,
      finalResult: result,
      finalResultTruncated: cut,
      childSessionId: child.id,
      link: (child.parentLink ?? SessionLink.spawn).name,
    );
  }
}
