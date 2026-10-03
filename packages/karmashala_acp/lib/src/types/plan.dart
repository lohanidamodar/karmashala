import 'package:meta/meta.dart';

import '../json.dart';
import 'enums.dart';

/// One line of the agent's plan.
@immutable
final class PlanEntry {
  const PlanEntry({
    required this.content,
    this.priority = PlanEntryPriority.medium,
    this.status = PlanEntryStatus.pending,
  });

  factory PlanEntry.fromJson(JsonMap json) => PlanEntry(
    content: json.string('content') ?? '',
    priority: switch (json.string('priority')) {
      final raw? => PlanEntryPriority.fromJson(raw),
      null => PlanEntryPriority.medium,
    },
    status: switch (json.string('status')) {
      final raw? => PlanEntryStatus.fromJson(raw),
      null => PlanEntryStatus.pending,
    },
  );

  final String content;
  final PlanEntryPriority priority;
  final PlanEntryStatus status;

  JsonMap toJson() => {
    'content': content,
    'priority': priority.toJson(),
    'status': status.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is PlanEntry &&
      other.content == content &&
      other.priority == priority &&
      other.status == status;

  @override
  int get hashCode => Object.hash(content, priority, status);
}
