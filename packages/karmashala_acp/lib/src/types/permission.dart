import 'package:meta/meta.dart';

import '../json.dart';
import 'enums.dart';

/// One answer the agent offers for a `session/request_permission`.
@immutable
final class PermissionOption {
  const PermissionOption({
    required this.optionId,
    required this.name,
    required this.kind,
  });

  factory PermissionOption.fromJson(JsonMap json) => PermissionOption(
    optionId: json.string('optionId') ?? '',
    name: json.string('name') ?? '',
    kind: PermissionOptionKind.fromJson(json.string('kind') ?? ''),
  );

  final String optionId;
  final String name;
  final PermissionOptionKind kind;

  JsonMap toJson() => {
    'optionId': optionId,
    'name': name,
    'kind': kind.toJson(),
  };
}

/// The client's answer: one of the offered options, or `cancelled` when the
/// turn was cancelled before anyone chose.
@immutable
sealed class PermissionOutcome {
  const PermissionOutcome();

  const factory PermissionOutcome.selected(String optionId, {JsonMap? meta}) =
      PermissionSelected;

  const factory PermissionOutcome.cancelled() = PermissionCancelled;

  factory PermissionOutcome.fromJson(JsonMap json) =>
      switch (json.string('outcome')) {
        'selected' => PermissionSelected(
          json.string('optionId') ?? '',
          meta: json.object('_meta'),
        ),
        _ => const PermissionCancelled(),
      };

  JsonMap toJson();
}

final class PermissionSelected extends PermissionOutcome {
  const PermissionSelected(this.optionId, {this.meta});

  final String optionId;

  /// What the client says beyond the choice — a question's answers.
  final JsonMap? meta;

  @override
  JsonMap toJson() => {
    'outcome': 'selected',
    'optionId': optionId,
    '_meta': ?meta,
  };

  @override
  bool operator ==(Object other) =>
      other is PermissionSelected && other.optionId == optionId;

  @override
  int get hashCode => optionId.hashCode;
}

final class PermissionCancelled extends PermissionOutcome {
  const PermissionCancelled();

  @override
  JsonMap toJson() => const {'outcome': 'cancelled'};

  @override
  bool operator ==(Object other) => other is PermissionCancelled;

  @override
  int get hashCode => 'cancelled'.hashCode;
}
