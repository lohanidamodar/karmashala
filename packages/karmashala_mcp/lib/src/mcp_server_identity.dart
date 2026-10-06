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
    'Once a session you started has ended and its work is merged or handed '
    'back, archive it with session_archive.';
