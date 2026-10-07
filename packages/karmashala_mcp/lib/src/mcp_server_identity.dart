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
    'To show the person something you made — an HTML page, a chart, an SVG, '
    'a mermaid diagram, markdown, an image or a PDF — write it to a file and '
    'call artifact_show with its absolute path: it opens in your thread, and '
    'rewriting the file makes a new revision. '
    'In your replies the chat itself draws fenced mermaid, diff, json and '
    'ansi blocks, a chart block (JSON: {"type": "bar"|"line", "title", '
    '"unit", "data": [{"label", "value"}] or [{"x": ISO date, "y"}]}) and '
    r'TeX math as $…$ or $$…$$; a file path you name opens as a preview. '
    'Once the work of a session you started is merged or handed back, end it '
    'with session_end, then archive it with session_archive, which takes only '
    'an ended session. You manage your children: nothing ends or archives '
    'them for you. '
    'When you start sessions, end your turn and wait for their reports — '
    'what they say with report_to_parent, and how they end, arrives as a '
    'message (every turn too, with report "each_turn"); do not poll '
    'transcripts or files. If a session started you, report to it with '
    'report_to_parent.';
