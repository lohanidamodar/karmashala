import 'package:agent_cli/descriptors.dart';

/// Whether two reports say the same thing about the same evidence.
/// `observedAt` is excluded: it moves every time anyone looks and only means
/// "we looked", so comparing it would make every reading a change.
bool sameStatusEvidence(AgentStatusReport a, AgentStatusReport b) =>
    a.status == b.status &&
    a.source == b.source &&
    a.detail == b.detail &&
    a.waiting == b.waiting &&
    a.sourceModifiedAt == b.sourceModifiedAt &&
    a.agentId == b.agentId &&
    a.sessionId == b.sessionId &&
    a.waitingSince == b.waitingSince &&
    (a.toolAsk == null ? b.toolAsk == null : a.toolAsk!.sameCallAs(b.toolAsk)) &&
    _sameLines(a.evidence, b.evidence);

bool _sameLines(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
