/// One usage window (e.g. a 5-hour or 7-day quota) as a percentage used, with
/// an optional reset time.
class UsageWindow {
  const UsageWindow({
    required this.label,
    required this.percent,
    this.resetsAt,
  });

  final String label;

  /// Percentage of the quota consumed, 0–100 (may exceed 100 on overage).
  final double percent;

  /// When this window's quota resets, if known.
  final DateTime? resetsAt;
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
