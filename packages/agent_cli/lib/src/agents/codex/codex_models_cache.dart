import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../adapter/agent_model_lister.dart';
import '../domain/agent_descriptor.dart';

/// Codex's own list of models: the account's catalogue it keeps in
/// `$CODEX_HOME/models_cache.json` (read 2026-09-23).
class CodexModelLister implements AgentModelLister {
  const CodexModelLister();

  @override
  Future<List<AgentModel>?> list(ModelListContext context) async {
    final env = context.hostEnvironment;
    final home =
        env['CODEX_HOME'] ??
        p.join(
          (context.hostIsWindows ? env['USERPROFILE'] : env['HOME']) ?? '.',
          '.codex',
        );
    final cache = File(p.join(home, 'models_cache.json'));
    if (!await cache.exists()) return null;
    return parseCodexModelsCache(await cache.readAsString());
  }
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
