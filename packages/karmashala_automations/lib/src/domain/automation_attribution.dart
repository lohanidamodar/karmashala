/// The line an automation's message into a session opens with, so the agent
/// and whoever reads the session know a person did not type it — and a chat
/// shows "Sent by automation Nightly" in its place, linked to the automation.
class AutomationAttribution {
  const AutomationAttribution({required this.automationId, required this.name});

  final String automationId;
  final String name;

  String get line =>
      '[sent by the Karmashala automation "$name" ($automationId)]';

  /// [message] after [line], on the same line: a terminal agent takes a
  /// newline typed into it as Enter.
  String render(String message) => '$line $message';

  static final _shape = RegExp(
    r'^\[sent by the Karmashala automation "(.*?)" \(([^()\s]+)\)\](?: |\n|$)',
  );

  /// Who sent [message] and what it said, or null when no automation did.
  static ({AutomationAttribution by, String rest})? split(String message) {
    final match = _shape.firstMatch(message);
    if (match == null) return null;
    return (
      by: AutomationAttribution(automationId: match[2]!, name: match[1]!),
      rest: message.substring(match.end).trimLeft(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AutomationAttribution &&
      other.automationId == automationId &&
      other.name == name;

  @override
  int get hashCode => Object.hash(automationId, name);
}
