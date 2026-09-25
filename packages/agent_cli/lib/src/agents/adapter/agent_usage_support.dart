import 'agent_usage_endpoint.dart';
import 'usage_limit_evidence.dart';

/// **What the app can learn about an agent's usage and limits.**
class AgentUsageSupport {
  const AgentUsageSupport({
    required this.endpoint,
    this.reportsResetTime = false,
    this.limitEvidence = const NoUsageLimitEvidence(),
  });

  /// Where a reading comes from.
  final AgentUsageEndpoint endpoint;

  /// Whether a reading names when a spent window resets — what lets a resume
  /// be scheduled for the reset rather than for a time the user picks.
  final bool reportsResetTime;

  /// What the agent itself leaves behind when a turn ends on a usage limit.
  final UsageLimitEvidence limitEvidence;
}
