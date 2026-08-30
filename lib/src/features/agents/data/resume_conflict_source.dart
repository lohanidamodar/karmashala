import '../domain/agent_descriptor.dart';

/// Whether [tailLines] show the agent refusing to resume a conversation another
/// process is already writing to.
///
/// The fourth thing read off an agent's own screen, and read there for the same
/// reason as the other three (see `TerminalGridStatusSource`): an interactive
/// CLI has no second stream to ask. Codex prints its refusal and exits, so this
/// is what turns a pane that just went dead into an explanation.
///
/// **Whitespace is removed from both the screen and the marker before
/// comparing.** A refusal is one long sentence — Codex's runs past 150
/// characters — so it hard-wraps at whatever width the pane happens to be, and
/// the wrap can land anywhere, including mid-word. A line-by-line substring
/// match would work at some pane widths and silently stop at others, which is
/// the worst failure shape available: a detector that is right in testing and
/// wrong in the field.
///
/// Returns false for an agent whose refusal we have never seen. An
/// undeclared marker means "we cannot explain this", never a guessed
/// explanation.
bool showsResumeConflict(AgentDescriptor? descriptor, List<String> tailLines) {
  final rules = descriptor?.launch.resumeConflict;
  if (rules == null || rules.isEmpty || tailLines.isEmpty) return false;
  final screen = _squeeze(tailLines.join(' '));
  for (final marker in rules.markers) {
    if (screen.contains(_squeeze(marker.contains))) return true;
  }
  return false;
}

/// Lower-cased with every whitespace character dropped.
String _squeeze(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'\s+'), '');
