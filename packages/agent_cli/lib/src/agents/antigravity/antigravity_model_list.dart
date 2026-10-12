import 'dart:convert';

import '../adapter/agent_model_lister.dart';
import '../domain/agent_descriptor.dart';

/// Antigravity's own list of models: `agy models` (agy 1.3.3, read
/// 2026-10-12) prints one `<id>\t<label>` line per model the account may use,
/// and its spinner on stderr.
class AntigravityModelLister implements AgentModelLister {
  const AntigravityModelLister();

  @override
  String get source => 'agy models';

  @override
  Future<List<AgentModel>?> list(ModelListContext context) async {
    final run = context.runLocalCli;
    if (run == null) return null;
    final stdout = await run(const [
      'models',
    ], timeout: const Duration(seconds: 30));
    return stdout == null ? null : parseAgyModels(stdout);
  }
}

final _ansi = RegExp(r'\x1B\[[0-9;?]*[A-Za-z]');
final _modelId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:/\[\]-]*$');

/// The models in `agy models`' output, in its order, or null when it names
/// none. A line whose first field is not an id (a spinner, a notice) is
/// skipped; a line with an id alone takes the id as its label.
List<AgentModel>? parseAgyModels(String stdout) {
  final seen = <String>{};
  final models = <AgentModel>[];
  for (final raw in const LineSplitter().convert(stdout)) {
    final line = raw.replaceAll(_ansi, '').trim();
    if (line.isEmpty) continue;
    final tab = line.indexOf('\t');
    final id = (tab < 0 ? line : line.substring(0, tab)).trim();
    if (!_modelId.hasMatch(id) || !seen.add(id)) continue;
    final label = tab < 0 ? '' : line.substring(tab + 1).trim();
    // An id alone on a line is only trusted when it looks like one: a word
    // such as "Usage:" never reaches here, but "models" would.
    if (tab < 0 && !id.contains(RegExp(r'[-.\d]'))) continue;
    models.add(
      AgentModel(id: id, label: label.isEmpty ? id : label, summary: ''),
    );
  }
  return models.isEmpty ? null : models;
}
