import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// One delegated agent, located but **not read**.
///
/// Claude Code writes each subagent to
/// `<projects>/<project>/<session-id>/subagents/agent-<id>.jsonl`, beside an
/// `agent-<id>.meta.json` naming what it was asked to do. This is that meta,
/// plus where its turns are — everything a collapsed row needs, and nothing
/// that costs a transcript read.
///
/// [toolUseId] is the whole join: it is the `id` of the `Task` tool call in the
/// *parent's* transcript, so a subagent file finds the row it belongs under
/// without anyone reconstructing a path or matching on a description.
class SubagentRef {
  const SubagentRef({
    required this.toolUseId,
    required this.filePath,
    required this.agentType,
    required this.description,
    required this.spawnDepth,
    this.model,
  });

  /// The parent's `tool_use.id` for the `Task` call that spawned this agent.
  final String toolUseId;

  /// The delegate's own transcript, in the same Claude Code JSONL shape as its
  /// parent's — so [readSubagentTranscript] is the ordinary reader.
  final String filePath;

  /// The agent definition it ran as: `Explore`, `general-purpose`, a project
  /// agent's name. Empty when the meta did not say.
  final String agentType;

  /// What it was asked to do, in the parent's words.
  final String description;

  /// 1 for an agent the session spawned, 2 for one a delegate spawned, and so
  /// on. Every depth lands in the same `subagents/` directory — one real
  /// session here holds 99 at depth 1, 16 at depth 2 and 3 at depth 3 — so the
  /// index below is flat and a nested call joins exactly like a top-level one.
  final int spawnDepth;

  /// The model it ran on, when the meta carried one. Some do not.
  final String? model;

  /// The wire form. [filePath] is the server machine's path: a client asks
  /// the server for the turns, never opens it.
  Map<String, Object?> toJson() => {
    'toolUseId': toolUseId,
    'filePath': filePath,
    'agentType': agentType,
    'description': description,
    'spawnDepth': spawnDepth,
    'model': ?model,
  };

  /// Throws [FormatException] without the join or the path.
  static SubagentRef fromJson(Map<String, Object?> json) {
    final toolUseId = json['toolUseId'];
    final filePath = json['filePath'];
    if (toolUseId is! String || filePath is! String) {
      throw const FormatException('subagent: no toolUseId or filePath');
    }
    final depth = json['spawnDepth'];
    final model = json['model'];
    return SubagentRef(
      toolUseId: toolUseId,
      filePath: filePath,
      agentType: _string(json['agentType']),
      description: _string(json['description']),
      spawnDepth: depth is int && depth > 0 ? depth : 1,
      model: model is String && model.isNotEmpty ? model : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SubagentRef && other.filePath == filePath;

  @override
  int get hashCode => filePath.hashCode;
}

/// Where a Claude Code session keeps its subagents: the transcript's own path
/// with the `.jsonl` dropped, plus `subagents`.
String subagentsDirectoryFor(String transcriptPath) =>
    p.join(p.withoutExtension(transcriptPath), 'subagents');

/// The subagents of the session recorded at [transcriptPath], keyed by the
/// parent `tool_use.id` each one answers.
Future<Map<String, SubagentRef>> readSubagentIndexFor(String transcriptPath) =>
    readSubagentIndexIn(subagentsDirectoryFor(transcriptPath));

/// The same, for a directory already known — which is how a *nested* subagent
/// is found: a delegate's transcript sits in the very directory that indexes
/// the delegates it spawned.
///
/// Best-effort in every direction, because Anthropic documents this layout as
/// internal and version-unstable. A directory that is not there, a meta that is
/// not JSON, a meta with no `toolUseId` to join on (one on this machine carries
/// `name` instead), a meta whose `.jsonl` has not been written yet — each is
/// skipped on its own, and none of them costs the parent transcript anything.
Future<Map<String, SubagentRef>> readSubagentIndexIn(String directory) async {
  final dir = Directory(directory);
  final found = <String, SubagentRef>{};
  final List<String> names;
  try {
    if (!await dir.exists()) return found;
    // One listing, then the metas by name. The listing is also what tells us
    // which transcripts exist, so the pairing costs no extra `stat` calls.
    names = [
      await for (final entity in dir.list(followLinks: false))
        p.basename(entity.path),
    ];
  } catch (_) {
    return found;
  }

  final transcripts = names.where((n) => n.endsWith('.jsonl')).toSet();
  for (final name in names) {
    if (!name.endsWith('.meta.json')) continue;
    final stem = name.substring(0, name.length - '.meta.json'.length);
    // A meta lands before its first turn does. Offering the row then would
    // promise turns that are not on disk yet; the next poll picks it up.
    if (!transcripts.contains('$stem.jsonl')) continue;
    final reference = await _readMeta(
      p.join(directory, name),
      p.join(directory, '$stem.jsonl'),
    );
    if (reference != null) found[reference.toolUseId] = reference;
  }
  return found;
}

Future<SubagentRef?> _readMeta(String metaPath, String transcriptPath) async {
  final Object? decoded;
  try {
    decoded = jsonDecode(await File(metaPath).readAsString());
  } catch (_) {
    // Half-written, not JSON, or gone since the listing.
    return null;
  }
  if (decoded is! Map) return null;
  final toolUseId = decoded['toolUseId'];
  // No id is no join. The row would have nowhere to hang.
  if (toolUseId is! String || toolUseId.isEmpty) return null;
  final depth = decoded['spawnDepth'];
  final model = decoded['model'];
  return SubagentRef(
    toolUseId: toolUseId,
    filePath: transcriptPath,
    agentType: _string(decoded['agentType']),
    description: _string(decoded['description']),
    spawnDepth: depth is int && depth > 0 ? depth : 1,
    model: model is String && model.isNotEmpty ? model : null,
  );
}

String _string(Object? value) => value is String ? value.trim() : '';
