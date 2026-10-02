part of '../data_request.dart';

// The ACP agents a person added (ACP design, C2): rows the server composes
// its agent registry from.

DataRequest<Object?>? _acpAgentsRequestFromJson(String kind, _Arguments args) =>
    switch (kind) {
      AcpAgentsList.name => const AcpAgentsList(),
      AcpAgentPut.name => AcpAgentPut(
        id: args.optionalString('id'),
        agentName: args.string('name'),
        command: args.string('command'),
        args: args.strings('args', orEmpty: true),
        env: _stringMap(args, 'env'),
        source: switch (args.optionalString('source')) {
          null || 'custom' => AcpAgentSource.custom,
          'registry' => AcpAgentSource.registry,
          final other => throw DataRefused.invalid(
            '$kind: "source" must be custom or registry, not $other',
          ),
        },
        registryId: args.optionalString('registryId'),
        iconUrl: args.optionalString('iconUrl'),
      ),
      AcpAgentDelete.name => AcpAgentDelete(args.string('id')),
      _ => null,
    };

Map<String, String> _stringMap(_Arguments args, String key) {
  final value = args.values[key];
  if (value == null) return const {};
  if (value is Map && value.values.every((item) => item is String)) {
    return value.cast<String, String>();
  }
  throw DataRefused.invalid('${args.kind}: "$key" must map names to strings');
}

/// A request of the person-added ACP agents.
sealed class AcpAgentsRequest<R> extends DataRequest<R> {
  const AcpAgentsRequest();
}

/// Every ACP agent a person added, oldest first.
final class AcpAgentsList extends AcpAgentsRequest<List<AcpAgentRow>> {
  const AcpAgentsList();

  static const String name = 'acpAgents.list';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(List<AcpAgentRow> result) => [
    for (final row in result) acpAgentRowToJson(row),
  ];

  @override
  List<AcpAgentRow> resultFromJson(Object? json) => _decode(kind, () {
    return [for (final row in _objects(json, kind)) acpAgentRowFromJson(row)];
  });
}

/// Keeps an ACP agent: created under a server-chosen id when [id] is null or
/// unknown, rewritten in place when it names a row. Refused
/// [DataRefusalCode.invalid] for a blank name or command.
final class AcpAgentPut extends AcpAgentsRequest<AcpAgentRow> {
  const AcpAgentPut({
    required this.agentName,
    required this.command,
    this.id,
    this.args = const [],
    this.env = const {},
    this.source = AcpAgentSource.custom,
    this.registryId,
    this.iconUrl,
  });

  static const String name = 'acpAgents.put';

  final String? id;
  final String agentName;
  final String command;
  final List<String> args;
  final Map<String, String> env;
  final AcpAgentSource source;
  final String? registryId;

  /// The registry entry's icon URL, kept so the agent is drawn with it.
  final String? iconUrl;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'id': ?id,
    'name': agentName,
    'command': command,
    'args': args,
    'env': env,
    'source': source.name,
    'registryId': ?registryId,
    'iconUrl': ?iconUrl,
  };

  @override
  Object? resultToJson(AcpAgentRow result) => acpAgentRowToJson(result);

  @override
  AcpAgentRow resultFromJson(Object? json) =>
      _decode(kind, () => acpAgentRowFromJson(_object(json, kind)));
}

/// Removes an ACP agent; one already gone is acknowledged.
final class AcpAgentDelete extends AcpAgentsRequest<DataAck> {
  const AcpAgentDelete(this.id);

  static const String name = 'acpAgents.delete';

  final String id;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id};

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}
