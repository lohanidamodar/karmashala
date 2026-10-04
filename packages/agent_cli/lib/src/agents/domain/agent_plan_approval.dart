import 'agent_tool_ask.dart';

/// **How an agent asks to leave plan mode and carry its plan out**, and how
/// that prompt is answered — declared data with evidence, read off the
/// descriptor, never decided by the agent's name.
///
/// Approve plan is the prompt's own approve and Stop is the turn's interrupt,
/// for every agent. Only Keep planning differs: by default it is the prompt's
/// own decline; [keepPlanningOption] names it by its words instead where the
/// decline could land on another "No".
class AgentPlanApprovalSupport {
  const AgentPlanApprovalSupport({
    this.toolName,
    this.toolKind,
    this.planKey = 'plan',
    this.keepPlanningOption,
    required this.evidence,
  }) : assert(toolName != null || toolKind != null);

  /// The CLI's own tool the ask names, when a hook names one.
  final String? toolName;

  /// The call's kind as an ACP agent names it (`switch_mode`): what tells a
  /// plan prompt whatever its title, from one translator or another.
  final String? toolKind;

  /// The key in the call's input holding the plan's text.
  final String planKey;

  /// A pattern for the menu option that keeps planning, picked by its words
  /// off the agent's screen; null when the prompt's decline is that answer.
  final String? keepPlanningOption;

  /// Where this was read, so a new version can be checked against it.
  final String evidence;

  /// The plan [ask] asks to carry out, or null when it is not this prompt.
  String? planIn(AgentToolAsk? ask) {
    if (ask == null) return null;
    final named = toolName != null && ask.toolName == toolName;
    final kinded = toolKind != null && ask.kind == toolKind;
    if (!named && !kinded) return null;
    final plan = ask.input[planKey];
    return plan is String && plan.trim().isNotEmpty ? plan : null;
  }

  /// The index of the keep-planning option among [options], or null.
  int? keepPlanningIn(List<String> options) {
    final pattern = keepPlanningOption;
    if (pattern == null) return null;
    final words = RegExp(pattern, caseSensitive: false);
    for (var i = 0; i < options.length; i++) {
      if (words.hasMatch(options[i].trim())) return i;
    }
    return null;
  }
}
