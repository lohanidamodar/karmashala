import '../../agents/domain/agent_descriptor.dart';

/// What forking *this* session would actually do.
///
/// The registry says what an **agent** can do ([AgentForkSupport]); this says
/// what can be done for one **session**, which is a different question with one
/// extra input: whether we know the CLI's own id for the conversation.
///
/// That input is not a detail. Codex will not accept a session id at launch, so
/// a native Codex row's `external_session_id` is null until something discovers
/// it — the gap Loop 46 §6 investigated and deliberately left open rather than
/// closing it with a guess. A fork needs to name the conversation being forked,
/// and `codex fork` with no id opens an interactive picker that chooses by
/// recency in a directory. Passing that off as "the fork worked" would forge the
/// one thing the user cares about: *which* conversation they branched.
///
/// So a capability of `native` is necessary and not sufficient, and the
/// degraded case is not an error — it is a handoff, named as one.
enum SessionForkKind {
  /// The CLI forks it, from its own record. History is shared exactly.
  native,

  /// The CLI cannot (or cannot be told which conversation), so a handoff packet
  /// carries a quoted recap instead. **A weaker thing**, and the UI says so
  /// before it happens.
  handoff,

  /// Neither is possible.
  refused,
}

/// The decision, with the words for explaining it.
class SessionForkPlan {
  const SessionForkPlan._(this.kind, this.explanation, {this.arguments});

  final SessionForkKind kind;

  /// Plain words shown to the user **before** the fork, naming the agent and
  /// what will really happen. Never empty.
  final String explanation;

  /// The command-line arguments for a [SessionForkKind.native] fork; null
  /// otherwise.
  final List<String>? arguments;

  bool get isNative => kind == SessionForkKind.native;
  bool get isRefused => kind == SessionForkKind.refused;

  /// Decides for a session of [agentName] running under [descriptor], whose
  /// CLI-side conversation id is [externalSessionId] (null when we never
  /// learned one).
  static SessionForkPlan decide({
    required AgentDescriptor? descriptor,
    required String agentName,
    String? externalSessionId,
  }) {
    final fork =
        descriptor?.launch.fork ?? const AgentForkSupport.unsupported();
    final id = externalSessionId ?? '';

    switch (fork.style) {
      case AgentForkStyle.native:
        if (id.isEmpty) {
          return SessionForkPlan._(
            SessionForkKind.handoff,
            '$agentName can fork a conversation, but Chitragupta never learned '
            'its id for this one, so there is nothing to name on the '
            'command line. This will hand off a written recap instead — the '
            'new session will not share $agentName\'s own record of the '
            'conversation.',
          );
        }
        return SessionForkPlan._(
          SessionForkKind.native,
          '$agentName forks this itself. The new session starts with the whole '
          'conversation and then diverges; this one is left exactly as it '
          'is.',
          arguments: fork.argumentsFor(id),
        );
      case AgentForkStyle.viaHandoff:
        return SessionForkPlan._(
          SessionForkKind.handoff,
          '$agentName cannot fork; this will hand off instead. The new session '
          'gets a written recap of the conversation, not $agentName\'s own '
          'record of it, so it will know what was said but not remember '
          'saying it.',
        );
      case AgentForkStyle.unsupported:
        // The default, and therefore also the answer for an agent nobody has
        // checked. It is deliberately a refusal rather than an inferred
        // handoff: whether a packet can be built and delivered depends on
        // whether the agent has a readable store *and* takes an opening prompt,
        // and quietly assuming both for an unexamined CLI is how a fork ends up
        // launching a blank session that has been told nothing.
        return SessionForkPlan._(
          SessionForkKind.refused,
          'Chitragupta has no verified way to fork a $agentName conversation, '
          'and none to carry one across as a written recap either. Start a '
          'new $agentName session and describe what you need instead.',
        );
    }
  }
}
