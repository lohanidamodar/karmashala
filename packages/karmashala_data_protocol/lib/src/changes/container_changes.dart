part of '../data_change.dart';

// A container being created (`containers.create`).

DataChange? _containerChangeFromJson(String name, Map<String, Object?> json) =>
    switch (name) {
      'containerProgress' => ContainerProgress(
        machineId: json['machineId']! as String,
        step: ContainerStep.values.firstWhere(
          (step) => step.name == json['step'],
          orElse: () => ContainerStep.settingUp,
        ),
        line: json['line'] as String?,
      ),
      _ => null,
    };

/// The steps of a create, in order.
enum ContainerStep {
  checking,
  pulling,
  starting,
  settingUp,
  connecting,
  detecting,
  done,
  failed,
}

/// A step of a create under way, and the latest line it printed, told to
/// every client so the row that asked can show it. Not a row: nothing copies
/// it. A key never appears in [line]: the scripts never print one.
final class ContainerProgress extends DataChange {
  const ContainerProgress({
    required this.machineId,
    required this.step,
    this.line,
  });

  final String machineId;
  final ContainerStep step;
  final String? line;

  @override
  Map<String, Object?> toJson() => {
    'change': 'containerProgress',
    'machineId': machineId,
    'step': step.name,
    'line': ?line,
  };
}
