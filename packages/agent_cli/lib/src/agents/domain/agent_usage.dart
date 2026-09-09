/// One usage window (e.g. a 5-hour or 7-day quota), with an optional reset
/// time and — when the endpoint measured one — how much of it is gone.
class UsageWindow {
  const UsageWindow({
    required this.label,
    this.percent,
    this.resetsAt,
    this.span,
  });

  final String label;

  /// Percentage of the quota consumed, 0–100 (may exceed 100 on overage), or
  /// **null when the payload carries no reading for this window at all**.
  ///
  /// Null is not zero, and this field is nullable because it once was: an
  /// Antigravity window was built with `percent: 0.0` from a `loadCodeAssist`
  /// reply that names the account's tiers and measures nothing, so a pane on it
  /// drew a confident `0%` for a quota nobody had read. Absent says what is
  /// true — the same answer `HealthLevel.unknown` gives one panel over — and
  /// every surface spells it out rather than a number ([kUsageNoQuotaReported]).
  final double? percent;

  /// When this window's quota resets, if known.
  ///
  /// **A quota reset, never a credential's expiry** — those are different
  /// facts and only one of them means the number goes back to zero. When the
  /// sign-in behind a reading has a lifetime, it belongs on
  /// [AgentUsage.tokenExpiresAt].
  final DateTime? resetsAt;

  /// **How long this window is**, when the endpoint's own key names one.
  ///
  /// Both vendors report a percentage *of a named period* — Claude's
  /// `five_hour` / `seven_day`, Codex's `primary_window` / `secondary_window` —
  /// so the period is a fact the payload carries, not a guess. It is what makes
  /// [percent] a rate rather than a bare number: one point of a five-hour quota
  /// takes at least three minutes to spend, whatever is spending it, because
  /// every pane on the account spends the same hundred points.
  ///
  /// `usageAskFloor` turns that into the floor under every request the app
  /// makes. Null where the endpoint names no period (a model-scoped limit with
  /// no group, paid overage, Antigravity's tiers), and the floor then falls back
  /// to `kUsageMinInterval` rather than inventing a period.
  final Duration? span;
}

/// **What every surface says about a window nothing measured.**
///
/// One phrase in one place, because a percentage — and its absence — has to
/// mean the same thing in the status bar, in Settings and in a fan-out.
const String kUsageNoQuotaReported = 'no quota reported';

/// A usage snapshot for one agent account: the quota windows plus when it was
/// fetched.
class AgentUsage {
  const AgentUsage({
    required this.windows,
    required this.fetchedAt,
    this.email,
    this.tokenExpiresAt,
  });

  final List<UsageWindow> windows;
  final DateTime fetchedAt;
  final String? email;

  /// When the credential this reading was taken with stops working, if the
  /// account's store says so.
  ///
  /// An account fact rather than a window's, and kept apart from
  /// [UsageWindow.resetsAt] on purpose: Antigravity's token expiry used to be
  /// written into that field, so the app said a quota it had never read would
  /// "reset" at the moment the user's sign-in lapsed. It is worth showing —
  /// for an account with no quota reading it is most of what is known — but as
  /// itself.
  final DateTime? tokenExpiresAt;

  bool get isEmpty => windows.isEmpty;
}
