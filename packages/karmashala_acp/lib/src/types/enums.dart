import 'wire_enum.dart';

/// Why a `session/prompt` turn ended.
final class StopReason extends WireEnum {
  const StopReason._(super.raw);
  const StopReason.unknown(super.raw) : super(isKnown: false);

  static const endTurn = StopReason._('end_turn');
  static const maxTokens = StopReason._('max_tokens');
  static const maxTurnRequests = StopReason._('max_turn_requests');
  static const refusal = StopReason._('refusal');
  static const cancelled = StopReason._('cancelled');

  static const known = [
    endTurn,
    maxTokens,
    maxTurnRequests,
    refusal,
    cancelled,
  ];

  factory StopReason.fromJson(String raw) =>
      lookupKnown(known, raw) ?? StopReason.unknown(raw);
}

/// What a tool call does, for an icon and a default risk reading.
final class ToolKind extends WireEnum {
  const ToolKind._(super.raw);
  const ToolKind.unknown(super.raw) : super(isKnown: false);

  static const read = ToolKind._('read');
  static const edit = ToolKind._('edit');
  static const delete = ToolKind._('delete');
  static const move = ToolKind._('move');
  static const search = ToolKind._('search');
  static const execute = ToolKind._('execute');
  static const think = ToolKind._('think');
  static const fetch = ToolKind._('fetch');
  static const switchMode = ToolKind._('switch_mode');
  static const other = ToolKind._('other');

  static const known = [
    read,
    edit,
    delete,
    move,
    search,
    execute,
    think,
    fetch,
    switchMode,
    other,
  ];

  factory ToolKind.fromJson(String raw) =>
      lookupKnown(known, raw) ?? ToolKind.unknown(raw);
}

final class ToolCallStatus extends WireEnum {
  const ToolCallStatus._(super.raw);
  const ToolCallStatus.unknown(super.raw) : super(isKnown: false);

  static const pending = ToolCallStatus._('pending');
  static const inProgress = ToolCallStatus._('in_progress');
  static const completed = ToolCallStatus._('completed');
  static const failed = ToolCallStatus._('failed');

  static const known = [pending, inProgress, completed, failed];

  factory ToolCallStatus.fromJson(String raw) =>
      lookupKnown(known, raw) ?? ToolCallStatus.unknown(raw);
}

final class PermissionOptionKind extends WireEnum {
  const PermissionOptionKind._(super.raw);
  const PermissionOptionKind.unknown(super.raw) : super(isKnown: false);

  static const allowOnce = PermissionOptionKind._('allow_once');
  static const allowAlways = PermissionOptionKind._('allow_always');
  static const rejectOnce = PermissionOptionKind._('reject_once');
  static const rejectAlways = PermissionOptionKind._('reject_always');

  static const known = [allowOnce, allowAlways, rejectOnce, rejectAlways];

  bool get allows => this == allowOnce || this == allowAlways;

  factory PermissionOptionKind.fromJson(String raw) =>
      lookupKnown(known, raw) ?? PermissionOptionKind.unknown(raw);
}

final class PlanEntryPriority extends WireEnum {
  const PlanEntryPriority._(super.raw);
  const PlanEntryPriority.unknown(super.raw) : super(isKnown: false);

  static const high = PlanEntryPriority._('high');
  static const medium = PlanEntryPriority._('medium');
  static const low = PlanEntryPriority._('low');

  static const known = [high, medium, low];

  factory PlanEntryPriority.fromJson(String raw) =>
      lookupKnown(known, raw) ?? PlanEntryPriority.unknown(raw);
}

final class PlanEntryStatus extends WireEnum {
  const PlanEntryStatus._(super.raw);
  const PlanEntryStatus.unknown(super.raw) : super(isKnown: false);

  static const pending = PlanEntryStatus._('pending');
  static const inProgress = PlanEntryStatus._('in_progress');
  static const completed = PlanEntryStatus._('completed');

  static const known = [pending, inProgress, completed];

  factory PlanEntryStatus.fromJson(String raw) =>
      lookupKnown(known, raw) ?? PlanEntryStatus.unknown(raw);
}
