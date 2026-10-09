import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:karmashala_core/util.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';

import 'real_home_guard.dart';

/// The key Karmashala's entry sits under in an agent's server map.
const String karmashalaMcpEntryName = 'karmashala';

/// The bridge flag that makes it serve only a run Karmashala started. Also how
/// an entry under [karmashalaMcpEntryName] is told apart from one the person
/// wrote by hand, which is never overwritten or removed.
const String karmashalaMcpSessionOnlyFlag = '--session-only';

/// The stdio entry that spawns the bridge at [bridgePath], spelled the way
/// [kind] runs it.
///
/// In WSL the bridge is a Windows program reached over interop, and a Linux
/// variable crosses to it only when `WSLENV` names it — so `env` names
/// `KARMASHALA_SESSION_ID`, which the agent pane set. A probe's
/// `KARMASHALA_DATA_DIR` needs no naming: a Win32 child of a WSL process
/// inherits the Windows environment `wsl.exe` was started with.
Map<String, Object?> karmashalaMcpEntry({
  required EnvironmentKind kind,
  required String bridgePath,
}) => kind == EnvironmentKind.wsl
    ? <String, Object?>{
        'command': '/usr/bin/env',
        'args': <String>[
          'WSLENV=KARMASHALA_SESSION_ID',
          bridgePath,
          karmashalaMcpSessionOnlyFlag,
        ],
      }
    : <String, Object?>{
        'command': bridgePath,
        'args': const <String>[karmashalaMcpSessionOnlyFlag],
      };

/// What an agent's user file holds under [karmashalaMcpEntryName].
enum KarmashalaMcpEntryState {
  /// No file, or no entry in it.
  absent,

  /// Ours, spelling exactly the entry this build would write.
  current,

  /// Ours, from another build or install path.
  stale,

  /// Somebody's own entry under that name. Never touched.
  foreign,
}

/// **Keeps Karmashala's entry in an agent's own MCP file** — for an agent with
/// no per-launch MCP, declared by [AgentMcpConfigSpec.installsKarmashalaEntry].
/// The rest of the file is the person's: only the one key changes, and the
/// text around the server map is kept byte for byte.
class AgentMcpEntryInstaller {
  const AgentMcpEntryInstaller();

  /// The user file [descriptor] keeps its servers in under [storeHome], or null
  /// when it declares no entry of ours.
  File? fileFor(AgentDescriptor descriptor, String storeHome) {
    final spec = descriptor.mcpConfig;
    if (!spec.installsKarmashalaEntry || spec.userFileName.isEmpty) return null;
    return File(p.normalize(p.join(storeHome, spec.userFileName)));
  }

  /// What the file holds now, measured against [entry].
  Future<KarmashalaMcpEntryState> stateOf(
    AgentDescriptor descriptor,
    String storeHome, {
    Map<String, Object?>? entry,
  }) async {
    final file = fileFor(descriptor, storeHome);
    if (file == null || !await file.exists()) {
      return KarmashalaMcpEntryState.absent;
    }
    final (_, root) = await _read(file);
    final existing = _servers(root, descriptor)[karmashalaMcpEntryName];
    if (existing == null) return KarmashalaMcpEntryState.absent;
    if (!_isOurs(existing)) return KarmashalaMcpEntryState.foreign;
    return entry != null && jsonEncode(existing) == jsonEncode(entry)
        ? KarmashalaMcpEntryState.current
        : KarmashalaMcpEntryState.stale;
  }

  /// Adds [entry], or updates ours to it. Writes nothing when the agent is not
  /// installed (no [storeHome]), when it is already current, or when the name
  /// is somebody else's. Returns the state the file is left in.
  Future<KarmashalaMcpEntryState> install(
    AgentDescriptor descriptor,
    String storeHome,
    Map<String, Object?> entry,
  ) async {
    final file = fileFor(descriptor, storeHome);
    if (file == null) return KarmashalaMcpEntryState.absent;
    final before = await stateOf(descriptor, storeHome, entry: entry);
    if (before == KarmashalaMcpEntryState.current ||
        before == KarmashalaMcpEntryState.foreign) {
      return before;
    }
    // Made only when the agent is really there, so a stranger's `~` stays
    // clean; its config folder may not exist until it is first customized.
    if (!await Directory(storeHome).exists()) {
      return KarmashalaMcpEntryState.absent;
    }
    await _rewrite(file, descriptor, (servers) {
      servers[karmashalaMcpEntryName] = entry;
    });
    return stateOf(descriptor, storeHome, entry: entry);
  }

  /// Takes ours back out. A foreign entry under the name stays. Returns the
  /// state the file is left in.
  Future<KarmashalaMcpEntryState> remove(
    AgentDescriptor descriptor,
    String storeHome,
  ) async {
    final file = fileFor(descriptor, storeHome);
    if (file == null) return KarmashalaMcpEntryState.absent;
    final before = await stateOf(descriptor, storeHome);
    if (before == KarmashalaMcpEntryState.absent ||
        before == KarmashalaMcpEntryState.foreign) {
      return before;
    }
    await _rewrite(file, descriptor, (servers) {
      servers.remove(karmashalaMcpEntryName);
    });
    return stateOf(descriptor, storeHome);
  }

  Future<(String, Map<String, Object?>)> _read(File file) async {
    final raw = await file.exists() ? await file.readAsString() : '';
    final trimmed = raw.trim().isEmpty ? '{}' : raw;
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map<String, Object?>) {
      throw FormatException('${file.path} is not a JSON object');
    }
    return (trimmed, decoded);
  }

  /// The server map, read along [AgentMcpConfigSpec.userServersPath]. Empty
  /// when any step is missing or not an object.
  Map<String, Object?> _servers(
    Map<String, Object?> root,
    AgentDescriptor descriptor,
  ) {
    Object? node = root;
    for (final key in descriptor.mcpConfig.userServersPath) {
      node = node is Map<String, Object?> ? node[key] : null;
    }
    return node is Map<String, Object?> ? node : const {};
  }

  /// Read, edit the server map, splice it back and rename over. One level of
  /// path only: the top-level key is replaced textually, keeping every byte
  /// around it, and the map itself is written two-space indented to sit in
  /// the file the way agy writes it.
  Future<void> _rewrite(
    File file,
    AgentDescriptor descriptor,
    void Function(Map<String, Object?> servers) edit,
  ) async {
    final path = descriptor.mcpConfig.userServersPath;
    if (path.length != 1) {
      throw UnsupportedError(
        'An entry can be kept only in a top-level server map; '
        '${descriptor.id} declares ${path.join('.')}',
      );
    }
    refuseRealHomeUnderTest(file.path);
    final (raw, root) = await _read(file);
    final servers = Map<String, Object?>.of(_servers(root, descriptor));
    edit(servers);
    final value = const JsonEncoder.withIndent(
      '  ',
    ).convert(servers).replaceAll('\n', '\n  ');
    // A file with nothing in it yet is written whole, so it reads like one
    // agy wrote; anything else keeps every byte outside the server map.
    final updated = root.isEmpty
        ? const JsonEncoder.withIndent('  ').convert({path.single: servers})
        : replaceTopLevelJsonValue(raw, path.single, value);
    await file.parent.create(recursive: true);
    final staged = File('${file.path}.karmashala-tmp');
    try {
      await staged.writeAsString(
        updated.endsWith('\n') ? updated : '$updated\n',
        flush: true,
      );
      await staged.rename(file.path);
    } finally {
      try {
        await staged.delete();
      } on FileSystemException {
        // Renamed away, which is the usual case.
      }
    }
  }

  /// Ours when it runs the bridge with [karmashalaMcpSessionOnlyFlag]: the
  /// flag is in every entry this class writes and in none a person would.
  bool _isOurs(Object? entry) {
    if (entry is! Map) return false;
    final args = entry['args'];
    return args is List &&
        args.contains(karmashalaMcpSessionOnlyFlag) &&
        [
          entry['command'],
          ...args,
        ].any((part) => part is String && part.contains('karmashala_mcp'));
  }
}
