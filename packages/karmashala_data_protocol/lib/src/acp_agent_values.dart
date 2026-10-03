/// The ACP agents a person added, as the wire carries them: the row itself is
/// `agent_cli`'s [AcpAgentRow], so the adapter it becomes needs no second
/// shape. Each reader throws [FormatException] on a value out of shape.
library;

import 'package:agent_cli/descriptors.dart';

export 'package:agent_cli/descriptors.dart' show AcpAgentRow, AcpAgentSource;

Map<String, Object?> acpAgentRowToJson(AcpAgentRow row) => {
  'id': row.id,
  'name': row.name,
  'command': row.command,
  'args': row.args,
  'env': row.env,
  'source': row.source.name,
  'registryId': ?row.registryId,
  'iconUrl': ?row.iconUrl,
  'createdAt': row.createdAt.toUtc().toIso8601String(),
};

AcpAgentRow acpAgentRowFromJson(Map<String, Object?> json) => AcpAgentRow(
  id: _string(json, 'id'),
  name: _string(json, 'name'),
  command: _string(json, 'command'),
  args: acpStringsFromJson(json['args'], 'args'),
  env: acpStringMapFromJson(json['env'], 'env'),
  source: _source(json['source']),
  registryId: _optional(json, 'registryId'),
  iconUrl: _optional(json, 'iconUrl'),
  createdAt: _date(json['createdAt']),
);

/// A list of strings, or none when absent; anything else is out of shape.
List<String> acpStringsFromJson(Object? value, String key) {
  if (value == null) return const [];
  if (value is List && value.every((item) => item is String)) {
    return List.unmodifiable(value.cast<String>());
  }
  throw FormatException('"$key" must be a list of strings');
}

/// An object of strings, or none when absent; anything else is out of shape.
Map<String, String> acpStringMapFromJson(Object? value, String key) {
  if (value == null) return const {};
  if (value is Map && value.values.every((item) => item is String)) {
    return Map.unmodifiable(value.cast<String, String>());
  }
  throw FormatException('"$key" must map names to strings');
}

AcpAgentSource _source(Object? name) {
  for (final source in AcpAgentSource.values) {
    if (source.name == name) return source;
  }
  throw FormatException('"source" must be custom or registry, not $name');
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String) return value;
  throw FormatException('"$key" must be a string');
}

String? _optional(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null || value is String) return value as String?;
  throw FormatException('"$key" must be a string or absent');
}

DateTime _date(Object? value) {
  final parsed = value is String ? DateTime.tryParse(value) : null;
  if (parsed == null) throw const FormatException('not a time');
  return parsed.toUtc();
}
