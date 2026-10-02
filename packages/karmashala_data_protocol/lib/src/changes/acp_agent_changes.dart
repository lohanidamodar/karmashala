part of '../data_change.dart';

// The ACP agents a person added (ACP design, C2).

DataChange? _acpAgentsChangeFromJson(String name, Map<String, Object?> json) =>
    switch (name) {
      'acpAgentChanged' => AcpAgentChanged(acpAgentRowFromJson(_row(json))),
      'acpAgentRemoved' => AcpAgentRemoved(json['id']! as String),
      _ => null,
    };

/// A change to the person-added ACP agents.
sealed class AcpAgentsChange extends DataChange {
  const AcpAgentsChange();
}

/// An ACP agent row as the server now holds it — added or rewritten.
final class AcpAgentChanged extends AcpAgentsChange {
  const AcpAgentChanged(this.row);

  final AcpAgentRow row;

  @override
  Map<String, Object?> toJson() => {
    'change': 'acpAgentChanged',
    'row': acpAgentRowToJson(row),
  };
}

final class AcpAgentRemoved extends AcpAgentsChange {
  const AcpAgentRemoved(this.id);

  final String id;

  @override
  Map<String, Object?> toJson() => {'change': 'acpAgentRemoved', 'id': id};
}
