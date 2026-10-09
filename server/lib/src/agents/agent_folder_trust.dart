import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart'
    show AgentFolderTrustFormat, AgentRegistry;
import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:karmashala_core/util.dart' show replaceTopLevelJsonValue;
import 'package:path/path.dart' as p;

/// Where [agentId]'s store home is on [environmentId], as a path this machine
/// opens, or null when it has none there.
typedef AgentStoreHome =
    Future<String?> Function(String environmentId, String agentId);

/// **Marks a folder Karmashala made as trusted in an agent's own settings**,
/// so the agent does not ask about it on its first start there.
///
/// Only for a folder Karmashala created moments before, empty: a session
/// without a project's scratch folder. Each one is its own git repository,
/// and the agents keep trust per folder (Claude Code per git root), so
/// trusting the scratch folder above them would not reach them.
///
/// Where and how is the agent's own declaration, its store's
/// `AgentFolderTrustSpec`: Claude Code's `projects` in `~/.claude.json`,
/// Codex's `[projects."<path>"]` tables in `~/.codex/config.toml`. A choice
/// already recorded for the folder is left as it is. An agent that declares
/// none is not touched.
class AgentFolderTrust {
  AgentFolderTrust({
    required AgentStoreHome storeHome,
    AgentRegistry Function()? registry,
  }) : _storeHome = storeHome,
       _registry = registry ?? (() => AgentRegistry.builtIn);

  final AgentStoreHome _storeHome;
  final AgentRegistry Function() _registry;

  /// How many times a file the agent saved while it was being edited is read
  /// again before the edit is given up.
  static const int maxAttempts = 3;

  /// Marks [folder] trusted for [agentId]; true when the agent's settings now
  /// carry a choice for it. [windowsAgent] is whether the agent runs as a
  /// Windows program, which decides how it spells the folder.
  Future<bool> trust({
    required String agentId,
    required EnvironmentPath folder,
    required bool windowsAgent,
  }) async {
    final spec = _registry().byId(agentId)?.store?.folderTrust;
    if (spec == null) return false;
    final home = await _storeHome(folder.environmentId, agentId);
    if (home == null || !await Directory(home).exists()) return false;
    final context = home.contains(r'\') ? p.windows : p.posix;
    final file = File(context.normalize(context.join(home, spec.settingsFile)));
    return switch (spec.format) {
      AgentFolderTrustFormat.jsonProjects => _json(
        file,
        (raw) => _jsonTrusting(raw, folder.path.replaceAll(r'\', '/')),
      ),
      AgentFolderTrustFormat.tomlProjects => _rewrite(
        file,
        (raw) => _tomlTrusting(raw, folder.path, windowsAgent: windowsAgent),
        missingIsEmpty: true,
      ),
      AgentFolderTrustFormat.jsonPathList => _json(
        file,
        (raw) => _jsonListTrusting(raw, spec.listKey, folder.path),
      ),
    };
  }

  Future<bool> _json(File file, _Edit edit) async {
    // No file is an agent that never ran here: it asks for far more than
    // trust on its first start, and a file made here would skip that.
    if (!await file.exists()) return false;
    return _rewrite(file, edit);
  }

  /// Read, edit, and rename over, read again from the start when the agent
  /// saved the file in between: renaming over its save would lose it.
  Future<bool> _rewrite(
    File file,
    _Edit edit, {
    bool missingIsEmpty = false,
  }) async {
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final exists = await file.exists();
      if (!exists && !missingIsEmpty) return false;
      final before = exists ? await file.stat() : null;
      final raw = exists ? await file.readAsString() : '';
      final _Edited edited;
      try {
        edited = edit(raw);
      } on FormatException {
        return false;
      }
      final text = switch (edited) {
        _Unchanged() => null,
        _Changed(:final text) => text,
      };
      if (text == null) return true;
      final staged = File('${file.path}.karmashala-tmp');
      try {
        await staged.writeAsString(text, flush: true);
        final now = await file.exists() ? await file.stat() : null;
        if (!_same(before, now)) continue;
        await staged.rename(file.path);
        return true;
      } finally {
        try {
          await staged.delete();
        } on FileSystemException {
          // Renamed onto the file, or never written.
        }
      }
    }
    return false;
  }

  static bool _same(FileStat? before, FileStat? now) {
    if (before == null || now == null) return before == null && now == null;
    return before.size == now.size && before.modified == now.modified;
  }
}

typedef _Edit = _Edited Function(String raw);

sealed class _Edited {}

final class _Unchanged extends _Edited {}

final class _Changed extends _Edited {
  _Changed(this.text);
  final String text;
}

/// The project entry written for a folder the agent has not seen, trusted:
/// the shape the agent writes itself.
const Map<String, Object?> _jsonProjectEntry = {
  'allowedTools': <Object?>[],
  'mcpContextUris': <Object?>[],
  'mcpServers': <String, Object?>{},
  'enabledMcpjsonServers': <Object?>[],
  'disabledMcpjsonServers': <Object?>[],
  'hasTrustDialogAccepted': true,
  'hasClaudeMdExternalIncludesApproved': false,
  'hasClaudeMdExternalIncludesWarningShown': false,
};

/// [raw] with `projects.<key>` trusted, the rest of the file as it was.
_Edited _jsonTrusting(String raw, String key) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('the settings are not an object');
  }
  final current = decoded['projects'];
  if (current != null && current is! Map<String, Object?>) {
    throw const FormatException('the projects are not an object');
  }
  final projects = Map<String, Object?>.from(current as Map? ?? const {});
  final entry = projects[key];
  if (entry is Map && entry['hasTrustDialogAccepted'] == true) {
    return _Unchanged();
  }
  projects[key] = entry is Map<String, Object?>
      ? {...entry, 'hasTrustDialogAccepted': true}
      : _jsonProjectEntry;
  return _Changed(
    replaceTopLevelJsonValue(raw, 'projects', jsonEncode(projects)),
  );
}

/// [raw] with [folder] appended to its top-level [key] array of paths, unless
/// it is already there.
_Edited _jsonListTrusting(String raw, String key, String folder) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('the settings are not an object');
  }
  final current = decoded[key];
  if (current != null && current is! List) {
    throw FormatException('$key is not a list');
  }
  final paths = [...?current as List?];
  if (paths.contains(folder)) return _Unchanged();
  return _Changed(
    replaceTopLevelJsonValue(raw, key, jsonEncode([...paths, folder])),
  );
}

/// [raw] with a `[projects."<folder>"]` table marking [folder] trusted, unless
/// the file already has a table for it. On Windows the folder is keyed in
/// lower case, as a literal string; elsewhere as a basic string.
_Edited _tomlTrusting(String raw, String folder, {required bool windowsAgent}) {
  final key = windowsAgent ? folder.toLowerCase() : folder;
  final header = RegExp(
    r'''^\s*\[projects\.(?:"((?:[^"\\]|\\.)*)"|'([^']*)')\]''',
  );
  for (final line in const LineSplitter().convert(raw)) {
    final match = header.firstMatch(line);
    if (match == null) continue;
    final named = match[1] != null
        ? match[1]!.replaceAll(r'\\', r'\').replaceAll(r'\"', '"')
        : match[2]!;
    if (windowsAgent ? named.toLowerCase() == key : named == key) {
      return _Unchanged();
    }
  }
  final quoted = windowsAgent && !key.contains("'")
      ? "'$key'"
      : '"${key.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
  final table = '[projects.$quoted]\ntrust_level = "trusted"\n';
  if (raw.trim().isEmpty) return _Changed(table);
  final separated = raw.endsWith('\n') ? raw : '$raw\n';
  return _Changed('$separated\n$table');
}
