import 'package:agent_cli/descriptors.dart';

/// What one plan update did to one item.
enum PlanChangeKind { completed, started, added, dropped }

/// One line of "what changed" between two snapshots of an agent's plan.
class PlanChange {
  const PlanChange(this.kind, this.text);

  final PlanChangeKind kind;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is PlanChange && other.kind == kind && other.text == text;

  @override
  int get hashCode => Object.hash(kind, text);

  @override
  String toString() => 'PlanChange(${kind.name}: $text)';
}

/// **What [after] changed of [before]**, matched by item text: every CLI
/// resends its whole list, so an item's words are its only identity. Empty
/// when [before] is null — a first plan is drawn whole, not as a diff.
List<PlanChange> planChanges(AgentPlan? before, AgentPlan after) {
  if (before == null) return const [];
  final was = {for (final item in before.items) item.text: item.state};
  final now = {for (final item in after.items) item.text};
  final completed = <PlanChange>[];
  final started = <PlanChange>[];
  final added = <PlanChange>[];
  for (final item in after.items) {
    final previous = was[item.text];
    if (previous == null) {
      added.add(PlanChange(PlanChangeKind.added, item.text));
    } else if (item.state != previous) {
      if (item.state == AgentPlanItemState.completed) {
        completed.add(PlanChange(PlanChangeKind.completed, item.text));
      } else if (item.state == AgentPlanItemState.inProgress) {
        started.add(PlanChange(PlanChangeKind.started, item.text));
      }
    }
  }
  return [
    ...completed,
    ...started,
    ...added,
    for (final item in before.items)
      if (!now.contains(item.text))
        PlanChange(PlanChangeKind.dropped, item.text),
  ];
}
