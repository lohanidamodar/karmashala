import 'agent_usage.dart';

/// What an agent's own newest rate-limit record says about the account's
/// limits — the durable trace of a usage limit being hit, for an agent that
/// persists no error record and fires no failure hook.
class RateLimitRecord {
  const RateLimitRecord({
    required this.windows,
    this.reachedType,
    this.recordedAt,
  });

  /// The windows it names, labelled like the usage endpoint's windows.
  final List<UsageWindow> windows;

  /// The agent's own word for which limit was reached, verbatim, or null.
  /// Opaque: only its presence is read.
  final String? reachedType;

  /// The record's own timestamp — when the agent knew this, not when we read it.
  final DateTime? recordedAt;

  /// Whether Codex said the limit was reached, or a window is at its ceiling.
  bool get limitReached =>
      reachedType != null ||
      windows.any((window) => (window.percent ?? 0) >= 100);

  /// The window that is refusing work: the spent one that resets last.
  UsageWindow? get blocking {
    UsageWindow? latest;
    for (final window in windows) {
      if ((window.percent ?? 0) < 100) continue;
      final resets = window.resetsAt;
      if (latest == null ||
          (resets != null &&
              (latest.resetsAt == null || resets.isAfter(latest.resetsAt!)))) {
        latest = window;
      }
    }
    return latest;
  }
}
