import '../../permissions/permission_risk.dart';
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
    this.approveOptions = const {},
    this.skippedOptions = const [],
    required this.evidence,
  }) : assert(toolName != null || toolKind != null);

  /// For a prompt whose approve is picked off the screen: a pattern for each
  /// "yes" option's words → the permission value (an axis value id on the
  /// descriptor) it switches the session to. Empty where the approve is the
  /// prompt's own, chosen elsewhere (an ACP server's rung rule).
  final Map<String, String> approveOptions;

  /// Patterns for "yes" options never chosen whatever they permit — one that
  /// also clears the conversation.
  final List<String> skippedOptions;

  /// **The approve option among [options] that keeps the session where it
  /// is**: the highest whose permission value [rungOf] puts at or below
  /// [ceiling]. Null when none does, or none can be read — then nothing may be
  /// pressed, since the highlighted one can be above it.
  int? approveIn(
    List<String> options, {
    required PermissionRisk ceiling,
    required PermissionRisk? Function(String valueId) rungOf,
  }) {
    bool any(Iterable<String> patterns, String option) => patterns.any(
      (p) => RegExp(p, caseSensitive: false).hasMatch(option),
    );
    int? chosen;
    PermissionRisk? at;
    for (var i = 0; i < options.length; i++) {
      final option = options[i].trim();
      if (any(skippedOptions, option)) continue;
      String? value;
      for (final MapEntry(key: pattern, value: id) in approveOptions.entries) {
        if (RegExp(pattern, caseSensitive: false).hasMatch(option)) {
          value = id;
          break;
        }
      }
      final rung = value == null ? null : rungOf(value);
      if (rung == null || !rung.isAtMost(ceiling)) continue;
      if (at == null || !rung.isAtMost(at)) {
        chosen = i;
        at = rung;
      }
    }
    return chosen;
  }

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
