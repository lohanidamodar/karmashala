// A CLI transcript as chat messages, and the session readings the view shares.

part of '../session_transcript_view.dart';

/// The pane of this window [sessionId] can be *shown* in, or null when it has
/// none. Read, not watched: a widget that must follow it watches
/// [paneOfSessionProvider].
String? sessionTerminalPane(WidgetRef ref, String sessionId) =>
    ref.read(paneSessionsProvider).paneOf(sessionId);

/// The agent a switched session's row names, as its turns are labelled.
typedef TranscriptAgent = ({String name, String agentId});

/// A CLI transcript as chat messages, with a compacted session's history shown
/// **once** — the summary restates everything before the last boundary.
@visibleForTesting
List<ChatMessage> chatMessagesFromTranscript(
  List<TranscriptMessage> messages, {
  Map<int, SubagentRef>? subagents,
  int earlier = 0,
  TranscriptAgent? Function(String installationId)? agentOf,
  String Function(String modelId)? modelLabelOf,
}) {
  // The **last** boundary: a session compacted twice has restated its history
  // twice, and only the newest summary covers all of it. [earlier] rows come
  // before [messages] (a server-read window), so its first row can be one.
  var from = 0;
  CompactionBoundary? boundary;
  final first = earlier > 0 ? 0 : 1;
  for (var i = messages.length - 1; i >= first; i--) {
    final compaction = messages[i].compaction;
    if (compaction != null) {
      from = i;
      boundary = compaction;
      break;
    }
  }

  // The summary is the CLI's words, recorded as a user turn: it is folded
  // under the notice, never drawn as the person's message.
  String? summaryOf(TranscriptMessage row) =>
      row.compaction != null && row.role == 'user' ? row.text : null;

  final out = <ChatMessage>[];
  if (boundary != null) {
    final trigger = boundary.trigger;
    final compacted = earlier + from;
    out.add(
      ChatMessage(
        role: kCompactionNoticeRole,
        // The count, because a reader must be able to tell how much is behind
        // the line. The trigger only when the record carried one.
        text:
            '$compacted earlier '
            '${compacted == 1 ? 'message' : 'messages'} were '
            'compacted away by the agent'
            '${trigger == null ? '' : ' ($trigger)'}. What it kept is the '
            'summary below; the transcript file still holds them, and so does '
            'search.',
        at: messages[from].at,
        detail: summaryOf(messages[from]),
      ),
    );
  }

  // In a switched session an agent is named where it starts speaking — the
  // thread's first agent row, and the first after each switch — not on every
  // turn it goes on taking: the divider already says who took over.
  String? lastNamed;
  // A turn names its model only where it changed, as the first one does.
  String? lastModel;
  for (var i = from; i < messages.length; i++) {
    final message = messages[i];
    // A subagent's own call: drawn as a step on its Agent row.
    if (message.parentToolUseId != null) continue;
    if (summaryOf(message) case final summary?) {
      if (i == from && boundary != null) continue;
      final trigger = message.compaction!.trigger;
      out.add(
        ChatMessage(
          role: kCompactionNoticeRole,
          text:
              'The agent compacted its context'
              '${trigger == null ? '' : ' ($trigger)'}. What it kept is the '
              'summary below.',
          at: message.at,
          detail: summary,
        ),
      );
      continue;
    }
    final reference = message.subagent;
    if (reference != null) subagents?[out.length] = reference;
    final installation = message.agentInstallationId;
    final switching = message.role == kAgentSwitchRole;
    final named =
        installation != null &&
        (switching || (message.role == 'agent' && installation != lastNamed));
    final agent = named ? agentOf?.call(installation) : null;
    if (switching) {
      lastNamed = null;
    } else if (named) {
      lastNamed = installation;
    }
    final model = message.role == 'agent' ? message.model : null;
    final modelChanged = model != null && model != lastModel;
    if (modelChanged) lastModel = model;
    out.add(
      ChatMessage(
        role: switching ? kAgentSwitchNoticeRole : message.role,
        text: message.text,
        tool: message.tool,
        thinking: message.thinking,
        at: message.at,
        // A background call is answered at once; its row runs as long as the
        // work it started does.
        pending:
            message.pendingToolUseId != null ||
            (message.background?.state.isRunning ?? false),
        pendingToolUseId: message.pendingToolUseId,
        agentName: named ? agent?.name ?? 'another agent' : null,
        agentId: agent?.agentId,
        queued: message.queued,
        images: message.images,
        model: modelChanged ? modelLabelOf?.call(model) ?? model : null,
      ),
    );
  }
  return out;
}

/// The status badge's reading as the transcript needs it. A failed session's
/// turn is over, so it is idle here.
TranscriptTurn transcriptTurnFor(AgentStatusReport? report) =>
    switch (report?.status) {
      AgentActivityStatus.working => TranscriptTurn.working,
      AgentActivityStatus.awaitingApproval => TranscriptTurn.awaitingUser,
      AgentActivityStatus.idle ||
      AgentActivityStatus.failed => TranscriptTurn.idle,
      AgentActivityStatus.unknown || null => TranscriptTurn.unknown,
    };

/// **Whether a chat view can be built for this session**, as a reading rather
/// than a fact about the agent. Watched, so the view redraws when it settles.
SessionChatView sessionChatView(WidgetRef ref, String sessionId) =>
    ref.watch(sessionChatViewProvider(sessionId));
