/// What `serverInfo` reports: the version of the tool surface, not of the app,
/// and it moves when the tools do.
const String kKarmashalaMcpName = 'karmashala';
const String kKarmashalaMcpVersion = '2.0.0';

/// The one paragraph a model reads before it has called anything.
const String kKarmashalaMcpInstructions =
    'These tools drive Karmashala itself — the sessions, terminal tabs, '
    'projects, notes, inbox and delivery state of the app this agent is '
    'running inside. Tools that name a session default to the session '
    'calling them, so omit sessionId to act on yourself. Anything Karmashala '
    'has not measured is reported as "not recorded" rather than guessed. '
    'Once the work of a session you started is merged or handed back, end it '
    'with session_end, then archive it with session_archive, which takes only '
    'an ended session. You manage your children: nothing ends or archives '
    'them for you. '
    'When you start sessions, end your turn and wait for their reports — '
    'what they say with report_to_parent, and how they end, arrives as a '
    'message (every turn too, with report "each_turn"); do not poll '
    'transcripts or files. If a session started you, report to it with '
    'report_to_parent.';
