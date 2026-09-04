/// **Why a usage lookup did not produce a number.**
///
/// Four failures used to arrive as one sentence and one grey dash, and the user
/// can act differently on every one of them: a rate limit needs them to *stop*
/// asking, an expired token needs them to run the agent once, an unreachable
/// endpoint needs nothing at all, and a malformed answer is ours to fix. The
/// same rule `HealthLevel.unknown` and `AgentStatusReport.evidence` are written
/// to — say what was observed, never what it might have been.
enum UsageFailureKind {
  /// The vendor answered `429`. **The one failure that retrying makes worse**:
  /// every extra request while a limit is in force is another one the limit
  /// counts, so this is the kind that arms the backoff.
  rateLimited,

  /// There is no usable credential: none stored, one the endpoint rejected
  /// (`401`), or one the OS would not release. The user fixes this by signing
  /// in, or by running the agent once so it refreshes its own token.
  auth,

  /// Nothing answered — offline, DNS, TLS, a timeout. Nobody's fault and
  /// nothing to do; it recovers on its own.
  unreachable,

  /// The vendor answered `5xx`. Like [rateLimited] in the only way that
  /// matters here — asking again immediately is pushing on something that is
  /// already unwell — and unlike it in what the user is told, because nobody is
  /// being throttled. The owner's own outage on 2026-09-04 was this shape: it
  /// cleared on its own, with nothing changed at either end.
  serverBusy,

  /// It answered, but not with usage: an unexpected status under 500, or a body
  /// that is not the shape we parse.
  unusable,

  /// We never asked. This agent has no usage endpoint, or its store could not
  /// be located, so there is no request to make and no limit to wait out.
  notAsked,
}

/// A short heading for [kind], in the words the settings panel uses.
///
/// Never the whole story — the exception's own message carries the detail, and
/// a heading that swallowed it would be the confident-but-vague sentence the
/// health panel was built to delete.
String usageFailureHeadline(UsageFailureKind kind) => switch (kind) {
  UsageFailureKind.rateLimited => 'Rate limited',
  UsageFailureKind.serverBusy => 'The usage service is having trouble',
  UsageFailureKind.auth => 'Sign-in needed',
  UsageFailureKind.unreachable => 'Could not reach the usage service',
  UsageFailureKind.unusable => 'The usage service answered with an error',
  UsageFailureKind.notAsked => 'Not checked',
};

/// A wait, in the shortest honest words: `45s`, `2m`, `1h`.
///
/// Seconds matter here and nowhere else in this feature — a backoff can be
/// shorter than a minute when the server names one, and `formatUsageDuration`
/// (built for quota countdowns) would round that to `0m`.
String describeUsageWait(Duration wait) {
  if (wait <= Duration.zero) return 'a moment';
  if (wait.inMinutes < 1) return '${wait.inSeconds}s';
  if (wait.inHours < 1) return '${wait.inMinutes}m';
  final minutes = wait.inMinutes - wait.inHours * 60;
  return minutes == 0 ? '${wait.inHours}h' : '${wait.inHours}h${minutes}m';
}
