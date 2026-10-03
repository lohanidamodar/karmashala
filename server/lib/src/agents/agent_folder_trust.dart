import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart' show AgentIds;
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
/// and both agents keep trust per folder (Claude Code per git root), so
/// trusting the scratch folder above them would not reach them.
///
/// Claude Code reads `hasTrustDialogAccepted` under `projects` in
/// `~/.claude.json`; Codex reads `trust_level` under `[projects."<path>"]` in
/// `~/.codex/config.toml`. A choice already recorded for the folder is left
/// as it is. Any other agent is not touched.
class AgentFolderTrust {
  AgentFolderTrust({required AgentStoreHome storeHome})
    : _storeHome = storeHome;

  final AgentStoreHome _storeHome;

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
    final edit = switch (agentId) {
      AgentIds.claudeCode => _claude,
      AgentIds.codex => _codex,
      _ => null,
    };
    if (edit == null) return false;
    final home = await _storeHome(folder.environmentId, agentId);
    if (home == null || !await Directory(home).exists()) return false;
    return edit(home, folder.path, windowsAgent);
  }

  Future<bool> _claude(String home, String folder, bool windowsAgent) async {
    final file = File(claudeSettingsFile(home));
    // No file is an agent that never ran here: it asks for far more than
    // trust on its first start, and a file made here would skip that.
    if (!await file.exists()) return false;
    return _rewrite(
      file,
      (raw) => _claudeTrusting(
        raw,
        windowsAgent ? folder.replaceAll(r'\', '/') : folder,
      ),
    );
  }

  Future<bool> _codex(String home, String folder, bool windowsAgent) =>
      _rewrite(
        File(p.join(home, 'config.toml')),
        (raw) => _codexTrusting(raw, folder, windowsAgent: windowsAgent),
        missingIsEmpty: true,
      );

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
      if (edited case _Unchanged()) return true;
      final staged = File('${file.path}.karmashala-tmp');
      try {
        await staged.writeAsString((edited as _Changed).text, flush: true);
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

/// Claude Code's settings file for the store home [home]: `~/.claude.json`
/// beside `~/.claude`, or inside a store moved with `CLAUDE_CONFIG_DIR`.
String claudeSettingsFile(String home) {
  final context = home.contains(r'\') ? p.windows : p.posix;
  return context.basename(home) == '.claude'
      ? context.join(context.dirname(home), '.claude.json')
      : context.join(home, '.claude.json');
}

/// The project entry Claude Code writes for a folder it has seen, trusted.
const Map<String, Object?> _claudeProjectEntry = {
  'allowedTools': <Object?>[],
  'mcpContextUris': <Object?>[],
  'mcpServers': <String, Object?>{},
  'enabledMcpjsonServers': <Object?>[],
  'disabledMcpjsonServers': <Object?>[],
  'hasTrustDialogAccepted': true,
  'hasClaudeMdExternalIncludesApproved': false,
  'hasClaudeMdExternalIncludesWarningShown': false,
};

_Edited _claudeTrusting(String raw, String key) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('Claude Code settings are not an object');
  }
  final current = decoded['projects'];
  if (current != null && current is! Map<String, Object?>) {
    throw const FormatException('Claude Code projects are not an object');
  }
  final projects = Map<String, Object?>.from(current as Map? ?? const {});
  final entry = projects[key];
  if (entry is Map && entry['hasTrustDialogAccepted'] == true) {
    return _Unchanged();
  }
  projects[key] = entry is Map<String, Object?>
      ? {...entry, 'hasTrustDialogAccepted': true}
      : _claudeProjectEntry;
  return _Changed(
    replaceTopLevelJsonValue(raw, 'projects', jsonEncode(projects)),
  );
}

/// [raw] with a `[projects."<folder>"]` table marking [folder] trusted, unless
/// the file already has a table for it. A Windows Codex keys a folder in
/// lower case with backslashes, as a literal string; elsewhere it is a basic
/// string.
_Edited _codexTrusting(
  String raw,
  String folder, {
  required bool windowsAgent,
}) {
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
