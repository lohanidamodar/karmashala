part of '../data_change.dart';

// The ACP agents a person added.

DataChange? _acpAgentsChangeFromJson(String name, Map<String, Object?> json) =>
    switch (name) {
      'acpAgentChanged' => AcpAgentChanged(acpAgentRowFromJson(_row(json))),
      'acpAgentRemoved' => AcpAgentRemoved(json['id']! as String),
      'acpInstallProgress' => AcpInstallProgress(
        environmentId: json['environmentId']! as String,
        registryId: json['registryId']! as String,
        step: AcpInstallStep.values.byName(json['step']! as String),
      ),
      _ => null,
    };

/// What the server is doing for an ACP agent it is installing.
enum AcpInstallStep { downloading, unpacking, detecting }

/// A step of an install under way (`acpAgents.install`), told to every client
/// so the row that asked can say what is happening. Not a row: nothing copies
/// it.
final class AcpInstallProgress extends DataChange {
  const AcpInstallProgress({
    required this.environmentId,
    required this.registryId,
    required this.step,
  });

  final String environmentId;
  final String registryId;
  final AcpInstallStep step;

  @override
  Map<String, Object?> toJson() => {
    'change': 'acpInstallProgress',
    'environmentId': environmentId,
    'registryId': registryId,
    'step': step.name,
  };
}

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
