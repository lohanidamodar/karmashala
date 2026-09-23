import 'dart:convert';

import './agent_descriptor.dart';

/// Where an agent's own list of models is read from, so the picker offers what
/// this account can actually run instead of a list curated on one day.
///
/// Both sources were read 2026-09-23: Claude Code 2.1.280 answers a
/// `list_models` control request in print mode, and Codex keeps the account's
/// catalogue in `$CODEX_HOME/models_cache.json`.

/// The arguments that put Claude Code in the mode that answers [kClaudeListModelsRequest].
const List<String> kClaudeListModelsArguments = [
  '-p',
  '--input-format',
  'stream-json',
  '--output-format',
  'stream-json',
  '--verbose',
];

const String _claudeListModelsId = 'karmashala-models';

/// One line on stdin; the CLI answers it and exits when stdin closes, without
/// starting a conversation.
const String kClaudeListModelsRequest =
    '{"type":"control_request","request_id":"$_claudeListModelsId",'
    '"request":{"subtype":"list_models"}}\n';

/// The models in Claude Code's answer to [kClaudeListModelsRequest], or null
/// when [stdout] carries no such answer — an older CLI, or a refusal.
List<AgentModel>? parseClaudeModelList(String stdout) {
  for (final line in const LineSplitter().convert(stdout)) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (decoded is! Map<String, Object?>) continue;
    if (decoded['type'] != 'control_response') continue;
    final response = decoded['response'];
    if (response is! Map<String, Object?>) continue;
    if (response['request_id'] != _claudeListModelsId) continue;
    if (response['subtype'] != 'success') return null;
    final body = response['response'];
    final rows = body is Map<String, Object?> ? body['models'] : null;
    if (rows is! List) return null;
    final models = [
      for (final row in rows)
        if (row is Map<String, Object?>) ?_claudeModel(row),
    ];
    return models.isEmpty ? null : models;
  }
  return null;
}

AgentModel? _claudeModel(Map<String, Object?> row) {
  final id = row['value'];
  // `default` is not a model: it is "no flag", which the picker already offers
  // as its own row, and passing it would pin a session to today's default.
  if (id is! String || id.isEmpty || id == 'default') return null;
  if (row['disabled'] == true) return null;
  final label = row['displayName'];
  final summary = row['description'];
  return AgentModel(
    id: id,
    label: label is String && label.isNotEmpty ? label : id,
    summary: summary is String ? summary : '',
  );
}

/// The listed models in Codex's `models_cache.json`, in its own order, or null
/// when [json] is not that file. Entries it marks hidden are left out, as its
/// own picker leaves them out.
List<AgentModel>? parseCodexModelsCache(String json) {
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return null;
  }
  final rows = decoded is Map<String, Object?> ? decoded['models'] : null;
  if (rows is! List) return null;
  final models = [
    for (final row in rows)
      if (row is Map<String, Object?>) ?_codexModel(row),
  ];
  return models.isEmpty ? null : models;
}

AgentModel? _codexModel(Map<String, Object?> row) {
  final id = row['slug'];
  if (id is! String || id.isEmpty) return null;
  final visibility = row['visibility'];
  if (visibility is String && visibility != 'list') return null;
  final label = row['display_name'];
  final summary = row['description'];
  return AgentModel(
    id: id,
    label: label is String && label.isNotEmpty ? label : id,
    summary: summary is String ? summary : '',
  );
}
