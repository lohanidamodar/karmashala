/// What this server announces in `welcome.features`, the one place a client
/// learns what it serves beyond the protocol number (spec §3.2 rule 3).
///
/// Additive and named: a feature is added here in the same commit that serves
/// it, and never removed while a deployed client may still ask for it.
const Set<String> kServerFeatures = <String>{
  // `sessions.transcript` pages, `.watch`/`.unwatch` and the
  // `transcriptChanged` notice (Stage 0 step 5).
  'sessions.transcript',
  // A switched companion link whose socket dropped is kept for
  // `kHostLinkResumeGrace` and taken back by a `link.resume` (Stage 0 step 16).
  'link.resume',
  // A switched link may `link.resume` onto a second socket while the first
  // still carries it — relay to LAN, make-before-break — and what was in
  // flight on the first is taken or dropped as a copy (Stage 0 step 18).
  'link.promote',
  // An empty sealed frame on a switched link is answered with one, so an
  // idle desktop can tell a half-open socket from a quiet one (step 18).
  'link.keepalive',
  // `sessions.transcript.subagent`: a delegate's turns (Stage 0 step 6).
  'sessions.transcript.subagent',
  // Readers of a record's raw lines, run on the server (Stage 0 step 7).
  'sessions.rewindPoints',
  'sessions.changedFiles',
  'sessions.openQuestion',
  // `sessions.transcript` answers `digest` when asked (the plan and open
  // calls before a client's window), and `sessions.transcript.turns` pages a
  // record's turns as text only, for export and recap (Stage 0 step 8).
  'sessions.transcript.digest',
  'sessions.transcript.turns',
  // `sessions.stats`: sessions' counts in one batched request, and an agent's
  // lifetime totals (Stage 0 step 9).
  'sessions.stats',
  // `sessions.media`: a session's pictures, extracted here; their bytes come
  // through `files.read` (Stage 0 step 10).
  'sessions.media',
  // `files.upload.abort`: a cancelled upload's staged part is deleted at
  // once, not when the link closes.
  'files.upload.abort',
  // An approval may carry `ask`, the prompt it answers, and is refused when
  // the prompt open now is another (Stage 2 step 1).
  'prompt.answer.ask',

  // `sessions.send` and `sessions.interrupt`: a client's chat sends and Stop,
  // typed here as host keys, once per `requestId` (Stage 2 step 2).
  'sessions.send',
  'sessions.interrupt',

  // `quickAccess.*`: folders pinned to every file browser, kept here for
  // every client and greeted with `quickAccessChanged`.
  'quickAccess',

  // Sessions whose agent speaks ACP: the server owns the process and the
  // conversation, which `sessions.transcript` serves from its own rows
  // (ACP design, C3).
  'acpSessions',
  // `sessions.send` to an ACP session nothing runs resumes it here and sends
  // the message as its first turn, answering `resumed` and any notice.
  'sessions.send.resumes',
  // `sessions.setMode` and `.setConfigOption`: an ACP session's mode and
  // options, as its agent announces them.
  'sessions.setMode',
  'sessions.setConfigOption',
  // `acpAgents.list`, `.put`, `.delete`: the ACP agents a person adds;
  // `acpAgents.install`: one the registry ships as an archive, installed here.
  'acpAgents',
  'acpAgents.install',
  // `acpAuth.*`: an ACP agent's login methods, chosen and remembered here.
  'acpAuth',
};
