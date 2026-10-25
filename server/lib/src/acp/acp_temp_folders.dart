import 'dart:async';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:path/path.dart' as p;

/// The file Antigravity's ACP server unpacks beside itself: what marks a
/// `%TEMP%\_MEI*` folder as one of its leftovers.
const String kAntigravityAcpMarker = 'agy_acp_licenses.txt';

const String _sweepingSuffix = '.karmashala-sweep';

/// A TEMP folder of Karmashala's own for each ACP agent started on this
/// Windows machine, removed once the agent has exited: a PyInstaller agent
/// unpacks itself into TEMP and leaves it behind when it is killed.
class AcpTempFolders {
  AcpTempFolders(this.root);

  final String root;
  final Set<String> _live = {};

  /// The folders of agents this server started that have not been released.
  Set<String> get live => Set.unmodifiable(_live);

  /// This, where an agent in [environment] gets one: a Windows host, and
  /// the agent on it rather than in WSL or over SSH.
  AcpTempFolders? forEnvironment(ExecutionEnvironment? environment) =>
      Platform.isWindows &&
          (environment == null ||
              environment.kind == EnvironmentKind.windowsNative)
      ? this
      : null;

  /// A new, empty folder for one launch.
  String create() {
    final parent = Directory(root)..createSync(recursive: true);
    final folder = parent.createTempSync('a').path;
    _live.add(folder);
    return folder;
  }

  static Map<String, String> variablesOf(String folder) => {
    'TMP': folder,
    'TEMP': folder,
  };

  /// Removes [folder], retrying while a dying process still holds a file.
  Future<void> release(
    String folder, {
    int attempts = 10,
    Duration pause = const Duration(seconds: 1),
  }) async {
    _live.remove(folder);
    for (var i = 0; i < attempts; i++) {
      final directory = Directory(folder);
      if (!directory.existsSync()) return;
      try {
        await directory.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(pause);
      }
    }
  }
}

/// What one sweep removed and what it left because a process holds it.
final class AcpTempSweep {
  const AcpTempSweep({
    this.removed = const [],
    this.held = const [],
    this.bytesFreed = 0,
  });

  final List<String> removed;
  final List<String> held;
  final int bytesFreed;

  String describe() {
    final megabytes = (bytesFreed / (1024 * 1024)).toStringAsFixed(0);
    return 'acp: swept ${removed.length} leftover agent temp folder(s), '
        'freed $megabytes MB; ${held.length} held by a running process, left';
  }
}

/// Removes every folder under [ownRoot] (Karmashala's agent TEMPs), and
/// every `_MEI*` folder in [systemTemp] holding [kAntigravityAcpMarker],
/// except those in [keep] (live launches whose agent may not have unpacked). A
/// folder a running process holds is left: it is renamed before it is
/// deleted, and Windows refuses the rename while any file in it is open.
Future<AcpTempSweep> sweepAcpTempFolders({
  required String ownRoot,
  String? systemTemp,
  Set<String> keep = const {},
}) async {
  final candidates = <Directory>[
    for (final folder in _folders(ownRoot))
      if (!keep.contains(folder.path)) folder,
    for (final folder in _folders(systemTemp))
      if (_isAgentLeftover(folder)) folder,
  ];
  final removed = <String>[];
  final held = <String>[];
  var bytes = 0;
  for (final folder in candidates) {
    final Directory claimed;
    try {
      claimed = folder.path.endsWith(_sweepingSuffix)
          ? folder
          : folder.renameSync('${folder.path}$_sweepingSuffix');
    } on FileSystemException {
      held.add(folder.path);
      continue;
    }
    final size = _sizeOf(claimed);
    try {
      await claimed.delete(recursive: true);
    } on FileSystemException {
      // Claimed, so no process held it; the next sweep finishes it.
    }
    removed.add(folder.path);
    bytes += size - (claimed.existsSync() ? _sizeOf(claimed) : 0);
  }
  return AcpTempSweep(removed: removed, held: held, bytesFreed: bytes);
}

Iterable<Directory> _folders(String? root) {
  if (root == null) return const [];
  final directory = Directory(root);
  if (!directory.existsSync()) return const [];
  try {
    return directory.listSync(followLinks: false).whereType<Directory>();
  } on FileSystemException {
    return const [];
  }
}

bool _isAgentLeftover(Directory folder) {
  final name = p.basename(folder.path);
  if (!name.startsWith('_MEI')) return false;
  // A sweep cut short already claimed it; its marker may be gone.
  if (name.endsWith(_sweepingSuffix)) return true;
  return File(p.join(folder.path, kAntigravityAcpMarker)).existsSync();
}

int _sizeOf(Directory folder) {
  var total = 0;
  try {
    for (final entry in folder.listSync(recursive: true, followLinks: false)) {
      if (entry is File) {
        try {
          total += entry.lengthSync();
        } on FileSystemException {
          // Gone or unreadable; not counted.
        }
      }
    }
  } on FileSystemException {
    // Partly listed.
  }
  return total;
}
