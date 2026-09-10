import 'package:agent_cli/descriptors.dart';

/// What forking *this* session would actually do.
///
/// The registry says what an **agent** can do ([AgentForkSupport]); this says
/// what can be done for one **session**, with one extra input: whether we know
/// the CLI's own id for the conversation. Codex will not accept a session id at
/// launch, and `codex fork` with no id opens a picker that chooses by recency —
/// forging the one thing the user cares about. So `native` is necessary and not
/// sufficient, and the degraded case is a handoff, named as one.
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
            '$agentName can fork a conversation, but Karmashala never learned '
            'its id for this one, so there is nothing to name on the '
            'command line. This will hand off a written recap instead — the '
            'new session will not share $agentName\'s own record of the '
            'conversation.',
          );
        }
        return SessionForkPlan._(
          SessionForkKind.native,
          // The second sentence is the weaker of two paths, named. A CLI's own
          // in-session branch switches the *running process* into a copy and
          // takes everything it is holding; this starts a second process from
          // outside and can only hand it the conversation. Says what is true of
          // any CLI rather than listing one CLI's grants and links.
          '$agentName forks this itself. The new session starts with the whole '
          'conversation and then diverges; this one is left exactly as it '
          'is.\n\n'
          'It is a **new process**, not this session branching in place, so '
          'only the conversation crosses: anything the running session is '
          'holding in memory — permissions granted for this session, work '
          'already in flight, any link the CLI opened for it — stays here. '
          'Use $agentName\'s own in-session branch command instead if you '
          'need those to come with you.',
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
        // The default, and therefore the answer for an agent nobody has
        // checked. Deliberately a refusal rather than an inferred handoff:
        // quietly assuming a readable store *and* an opening prompt for an
        // unexamined CLI is how a fork launches a blank session told nothing.
        return SessionForkPlan._(
          SessionForkKind.refused,
          'Karmashala has no verified way to fork a $agentName conversation, '
          'and none to carry one across as a written recap either. Start a '
          'new $agentName session and describe what you need instead.',
        );
    }
  }
}
