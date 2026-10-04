import 'package:agent_cli/descriptors.dart';

/// What forking *this* session would actually do. `native` is necessary and not
/// sufficient: `codex fork` with no id picks by recency, which forges the id.
enum SessionForkKind {
  /// The CLI forks it, from its own record. History is shared exactly.
  native,

  /// The CLI cannot, or cannot be told which conversation, so a packet carries
  /// a quoted recap instead. **A weaker thing**, and the UI says so first.
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

  /// Decides for a session of [agentName] under [descriptor], whose CLI-side
  /// conversation id is [externalSessionId] — null when we never learned one.
  /// [switched]: more than one agent ran the session, so the CLI's own fork
  /// would carry only its own part of the thread.
  static SessionForkPlan decide({
    required AgentDescriptor? descriptor,
    required String agentName,
    String? externalSessionId,
    bool switched = false,
  }) {
    final fork =
        descriptor?.launch.fork ?? const AgentForkSupport.unsupported();
    final id = externalSessionId ?? '';

    switch (fork.style) {
      case AgentForkStyle.native:
        if (switched) {
          return SessionForkPlan._(
            SessionForkKind.handoff,
            'More than one agent has run this session, and $agentName\'s own '
            'fork would carry only its part of the conversation. This will '
            'hand off a written recap of the whole thread instead.',
          );
        }
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
          // The weaker of two paths, named: a CLI's own branch takes the
          // running process with it; this can only hand over the conversation.
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
        // The default, and the answer for an agent nobody has checked. A
        // refusal, not an inferred handoff: assuming both would launch a blank.
        return SessionForkPlan._(
          SessionForkKind.refused,
          'Karmashala has no verified way to fork a $agentName conversation, '
          'and none to carry one across as a written recap either. Start a '
          'new $agentName session and describe what you need instead.',
        );
    }
  }
}
