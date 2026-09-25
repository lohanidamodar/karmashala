import '../domain/rate_limit_record.dart';

/// **What an agent leaves behind when a turn ends on a usage limit** — only
/// ever evidence the agent itself wrote, never an inference from silence.
sealed class UsageLimitEvidence {
  const UsageLimitEvidence();
}

/// The agent records nothing that tells a usage limit apart.
final class NoUsageLimitEvidence extends UsageLimitEvidence {
  const NoUsageLimitEvidence();
}

/// A failure hook names [reason] — which may also be a passing rate limit, so
/// a usage reading must confirm a window is actually spent.
final class HookFailureReasonEvidence extends UsageLimitEvidence {
  const HookFailureReasonEvidence(this.reason);

  final String reason;
}

/// The agent's state file records its rate limits; [read] takes the newest
/// record from the file at a path.
final class StateFileRateLimitEvidence extends UsageLimitEvidence {
  const StateFileRateLimitEvidence(this.read);

  final Future<RateLimitRecord?> Function(String stateFilePath) read;
}
