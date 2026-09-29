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
};
