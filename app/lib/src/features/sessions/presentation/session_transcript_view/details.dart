// What hangs under a row — subagents, delegations, artifacts, visuals — and the transcript mapping.

part of '../session_transcript_view.dart';

mixin _TranscriptDetails on ConsumerState<SessionTranscriptView> {
  String? Function(String)? _hostPathResolver();

  /// Which delegated agent hangs under which row, by the row's index in the
  /// whole transcript. Read back by [ChatTranscriptView.detailBuilder].
  var _subagents = <int, SubagentRef>{};

  /// Children started together, by the row their folded card hangs under.
  var _delegations = <int, List<DelegationCall>>{};

  /// Replaced only when [_subagents] changes: the transcript's rows compare
  /// their callbacks, and a fresh closure on every poll would rebuild them all.
  late MessageDetailBuilder _detailBuilder = _subagentDetailFor(_subagents);

  /// [_detailBuilder] with each artifact's card under the row of its turn,
  /// rebuilt only when that builder or the placement moves.
  MessageDetailBuilder? _withArtifacts;
  MessageDetailBuilder? _artifactsBase;
  String? _artifactsKey;
  ArtifactPlacement _placement = ArtifactPlacement.empty;
  VisualPlacement _visualPlacement = VisualPlacement.empty;

  MessageDetailBuilder _detailWithArtifacts(
    List<ChatMessage> messages,
    List<Artifact> artifacts,
    List<SessionVisual> visuals,
  ) {
    final placement = placeArtifacts(messages, artifacts);
    final visualPlacement = placeVisuals(messages, visuals);
    final key = [
      for (final entry in placement.byOrdinal.entries)
        '${entry.key}:${entry.value.map((a) => a.id).join(',')}',
      'u:${placement.unplaced.map((a) => a.id).join(',')}',
      'v:${visualPlacement.key}',
    ].join(';');
    if (_withArtifacts != null &&
        identical(_artifactsBase, _detailBuilder) &&
        key == _artifactsKey) {
      return _withArtifacts!;
    }
    _artifactsBase = _detailBuilder;
    _artifactsKey = key;
    _placement = placement;
    _visualPlacement = visualPlacement;
    final base = _detailBuilder;
    final placed = placement.byOrdinal;
    final drawn = visualPlacement.byOrdinal;
    final sessionId = widget.sessionId;
    return _withArtifacts = placed.isEmpty && drawn.isEmpty
        ? base
        : (message, ordinal) {
            final lead = base(message, ordinal);
            final cards = placed[ordinal];
            final visuals = drawn[ordinal];
            if (cards == null && visuals == null) return lead;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                ?lead,
                for (final artifact in cards ?? const <Artifact>[])
                  ArtifactCard(artifact: artifact),
                if (visuals != null)
                  SessionVisualBlocks(sessionId: sessionId, visualIds: visuals),
              ],
            );
          };
  }

  /// What hangs under a row: the subagent it spawned, and the ask about it
  /// while one is open.
  MessageDetailBuilder _subagentDetailFor(Map<int, SubagentRef> subagents) =>
      (message, ordinal) {
        final reference = subagents[ordinal];
        final callId = message.pending ? message.pendingToolUseId : null;
        final ask = callId == null
            ? null
            : ChatToolAsk(
                sessionId: widget.sessionId,
                toolUseId: callId,
                toolName: message.tool?.name,
              );
        final Widget? lead;
        if (reference == null) {
          final calls = _delegations[ordinal];
          lead = calls == null
              ? null
              : DelegationGroupCard(
                  parentSessionId: widget.sessionId,
                  calls: calls,
                );
        } else {
          lead = SubagentTurnsTile(
            reference: reference,
            resolveHostPath: _hostPathResolver(),
            sessionId: widget.sessionId,
          );
        }
        if (lead == null || ask == null) return lead ?? ask;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [lead, ask],
        );
      };

  /// Each agent of a switched thread by name — with where it lives when two
  /// installations of one agent took turns in it.
  TranscriptAgent? Function(String) _agentsIn(
    List<TranscriptMessage> messages,
  ) {
    final rows = ref.read(agentInstallationsDataProvider);
    final labels = installationLabelsOf(
      {for (final message in messages) ?message.agentInstallationId},
      rows: rows,
      environments: ref.read(environmentsDataProvider),
      registry: ref.read(agentRegistryProvider),
    );
    return (installationId) {
      final agentId = rows.getById(installationId)?.agentId;
      final name = labels[installationId];
      if (agentId == null || name == null) return null;
      return (name: name, agentId: agentId);
    };
  }

  /// The agent's own transcript as chat messages. The subagent a row spawned
  /// travels beside them, not inside [ChatMessage], which has no room for it.
  List<ChatMessage> _fromTranscript(
    List<TranscriptMessage> messages, {
    int earlier = 0,
    String Function(String modelId)? modelLabelOf,
  }) {
    final subagents = <int, SubagentRef>{};
    final out = chatMessagesFromTranscript(
      messages,
      subagents: subagents,
      earlier: earlier,
      agentOf: _agentsIn(messages),
      modelLabelOf: modelLabelOf,
    );
    final delegations = delegationGroups(out);
    if (!mapEquals(subagents, _subagents) ||
        delegationGroupsKey(delegations) != delegationGroupsKey(_delegations)) {
      _subagents = subagents;
      _delegations = delegations;
      _detailBuilder = _subagentDetailFor(subagents);
    }
    return out;
  }

  /// Maps the persisted event log to displayable chat messages, dropping
  /// lifecycle/status noise (verbose logs are not shown in the chat).
  List<ChatMessage> _toMessages(List<SessionEvent> events) {
    final messages = <ChatMessage>[];
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
            const ChatMessage(role: 'error', text: 'Session failed.'),
          );
        case SessionEventTypes.toolCall:
          _addToolCall(messages, event.payload);
        case SessionEventTypes.sessionCancelled:
          messages.add(const ChatMessage(role: 'tool', text: 'Session ended.'));
      }
    }
    return messages;
  }

  /// A tool call from the engine's own event log. It cannot yet show what came
  /// back: `SessionEventTypes.toolResult` is named and nothing emits it.
  void _addToolCall(List<ChatMessage> out, String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) return;
      final name = decoded['name'];
      if (name is! String || name.isEmpty) return;
      final activity = toolActivityFor(name, decoded['input']);
      out.add(
        ChatMessage(role: 'tool', text: activity.summary, tool: activity),
      );
    } on FormatException {
      // not JSON
    }
  }

  void _addText(List<ChatMessage> out, String role, String payload) {
    final text = _text(payload);
    if (text.isNotEmpty) out.add(ChatMessage(role: role, text: text));
  }

  String _text(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) {
        return (decoded['text'] ?? '').toString();
      }
    } on FormatException {
      // not JSON
    }
    return '';
  }
}
