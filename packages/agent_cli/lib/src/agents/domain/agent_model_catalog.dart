import './agent_descriptor.dart';

/// How long a model list read from an agent is trusted before a read asks the
/// agent again rather than answering from the cache.
const Duration kAgentModelsTtl = Duration(hours: 6);

/// What one agent installation last reported as its models, kept by the
/// server per installation: when it was read, from what, and how the last
/// attempt went. [models] empty means nothing was ever read, so the curated
/// list stands.
class AgentModelCatalog {
  const AgentModelCatalog({
    required this.installationId,
    this.models = const [],
    this.readAt,
    this.source,
    this.failure,
    this.failedAt,
  });

  final String installationId;

  /// The agent's own list from its last good read, in its order.
  final List<AgentModel> models;

  /// When [models] was read; null when it never was.
  final DateTime? readAt;

  /// Where the list is read from (`agy models`); null when the agent lists
  /// none, which is what "Curated list (agent lists none)" says.
  final String? source;

  /// Why the newest attempt failed, when it did. [models] is then the last
  /// good list, or empty.
  final String? failure;
  final DateTime? failedAt;

  bool get isLive => models.isNotEmpty;

  /// Whether [now] is [ttl] or more past [readAt] (or nothing was read).
  bool isStale(DateTime now, Duration ttl) {
    final read = readAt;
    return read == null || !now.isBefore(read.add(ttl));
  }

  Map<String, Object?> toJson() => {
    'installationId': installationId,
    'models': [for (final model in models) agentModelToJson(model)],
    'readAt': ?readAt?.toUtc().toIso8601String(),
    'source': ?source,
    'failure': ?failure,
    'failedAt': ?failedAt?.toUtc().toIso8601String(),
  };

  factory AgentModelCatalog.fromJson(Map<String, Object?> json) {
    DateTime? time(String key) {
      final value = json[key];
      return value is String ? DateTime.tryParse(value)?.toUtc() : null;
    }

    final rows = json['models'];
    return AgentModelCatalog(
      installationId: json['installationId'] as String,
      models: [
        if (rows is List)
          for (final row in rows)
            if (row is Map<String, Object?>) ?agentModelFromJson(row),
      ],
      readAt: time('readAt'),
      source: json['source'] as String?,
      failure: json['failure'] as String?,
      failedAt: time('failedAt'),
    );
  }
}

Map<String, Object?> agentModelToJson(AgentModel model) => {
  'id': model.id,
  'label': model.label,
  'summary': model.summary,
  'resolvedId': ?model.resolvedId,
};

AgentModel? agentModelFromJson(Map<String, Object?> json) {
  final id = json['id'];
  if (id is! String || id.isEmpty) return null;
  final label = json['label'];
  final summary = json['summary'];
  final resolved = json['resolvedId'];
  return AgentModel(
    id: id,
    label: label is String && label.isNotEmpty ? label : id,
    summary: summary is String ? summary : '',
    resolvedId: resolved is String ? resolved : null,
  );
}

/// The picker's list: [live] decides which models there are and in what
/// order. The agent's own label and summary win; a [curated] entry for the
/// same id fills in what the agent left bare, and an id nobody labelled is
/// named from the id ([modelLabelFromId]). Curated ids the agent no longer lists are
/// dropped. An empty [live] is no list at all: [curated] stands.
List<AgentModel> mergeModelLists({
  required List<AgentModel> curated,
  required List<AgentModel> live,
}) {
  if (live.isEmpty) return curated;
  final known = {for (final model in curated) model.id: model};
  return [
    for (final model in live)
      AgentModel(
        id: model.id,
        label: model.label.isNotEmpty && model.label != model.id
            ? model.label
            : known[model.id]?.label ?? modelLabelFromId(model.id),
        summary: model.summary.isNotEmpty
            ? model.summary
            : known[model.id]?.summary ?? '',
        resolvedId: model.resolvedId ?? known[model.id]?.resolvedId,
      ),
  ];
}

const _acronyms = {'gpt', 'oss', 'ai', 'agy', 'xl'};

/// A readable name for a model id nobody labelled: `argon-4` reads
/// "Argon 4", `gpt-oss-120b` "GPT OSS 120b".
String modelLabelFromId(String id) {
  final words = id
      .split(RegExp(r'[-_\s]+'))
      .where((word) => word.isNotEmpty)
      .map(
        (word) => _acronyms.contains(word.toLowerCase())
            ? word.toUpperCase()
            : '${word[0].toUpperCase()}${word.substring(1)}',
      );
  final label = words.join(' ');
  return label.isEmpty ? id : label;
}
