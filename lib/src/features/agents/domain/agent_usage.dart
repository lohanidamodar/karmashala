/// One usage window (e.g. a 5-hour or 7-day quota) as a percentage used, with
/// an optional reset time.
class UsageWindow {
  const UsageWindow({
    required this.label,
    required this.percent,
    this.resetsAt,
    this.span,
  });

  final String label;

  /// Percentage of the quota consumed, 0–100 (may exceed 100 on overage).
  final double percent;

  /// When this window's quota resets, if known.
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

/// A usage snapshot for one agent account: the quota windows plus when it was
/// fetched.
class AgentUsage {
  const AgentUsage({
    required this.windows,
    required this.fetchedAt,
    this.email,
  });

  final List<UsageWindow> windows;
  final DateTime fetchedAt;
  final String? email;

  bool get isEmpty => windows.isEmpty;
}
