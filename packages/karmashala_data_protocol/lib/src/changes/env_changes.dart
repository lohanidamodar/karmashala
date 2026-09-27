part of '../data_change.dart';

// The server's environment vault (slice 5a), as every client may know it:
// names and when each was set. Never a value.

DataChange? _envChangeFromJson(String name, Map<String, Object?> json) =>
    switch (name) {
      'envVariablesChanged' => EnvVariablesChanged([
        for (final item in json['variables']! as List)
          EnvVariableName.fromJson((item as Map).cast<String, Object?>()),
      ]),
      _ => null,
    };

/// The vault's names, whole, as they now stand — told after every set and
/// remove, and to a client that subscribes.
final class EnvVariablesChanged extends DataChange {
  const EnvVariablesChanged(this.variables);

  final List<EnvVariableName> variables;

  @override
  Map<String, Object?> toJson() => {
    'change': 'envVariablesChanged',
    'variables': [for (final variable in variables) variable.toJson()],
  };
}
