import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:riverpod/riverpod.dart';

/// Turns a copy of the app into a **probe**: a second instance for testing a
/// change while the real one keeps running. See PROJECT.md §23.
const String kProbeEnvironmentVariable = 'KARMASHALA_PROBE';

/// The existing data-folder override, which a probe requires.
const String kDataDirectoryEnvironmentVariable = 'KARMASHALA_DATA_DIR';

/// Whether this process is a probe, read **once** from the environment. Every
/// site that writes outside the data folder or binds a shared port asks this.
class ProbeMode {
  const ProbeMode({required this.enabled, this.dataDirectory});

  static const ProbeMode off = ProbeMode(enabled: false);

  /// A probe, for tests that need one without an environment.
  static const ProbeMode on = ProbeMode(enabled: true);

  /// `1`, `true`, `yes` or `on`, any case. Anything else — `0` included — is
  /// off, so clearing the variable by setting it to `0` does what it says.
  factory ProbeMode.fromEnvironment(Map<String, String> environment) {
    final raw = environment[kProbeEnvironmentVariable]?.trim().toLowerCase();
    final enabled = const {'1', 'true', 'yes', 'on'}.contains(raw);
    final dir = environment[kDataDirectoryEnvironmentVariable]?.trim();
    return ProbeMode(
      enabled: enabled,
      dataDirectory: dir == null || dir.isEmpty ? null : dir,
    );
  }

  /// This process's answer. Environment variables cannot change under a
  /// running process, so reading them once is not a cache that can go stale.
  static final ProbeMode current = ProbeMode.fromEnvironment(
    Platform.environment,
  );

  final bool enabled;

  /// `KARMASHALA_DATA_DIR` as given, or null. Shown in the probe banner.
  final String? dataDirectory;

  /// What a probe does not do, in the words the banner and the log use.
  static const List<String> disabledEffects = [
    'agent hooks and their endpoint files',
    'spool draining',
    'agent skill installation',
    'launch at login',
    'the global launcher hotkey',
    'remote access, the local relay and phone pairing',
    'the fixed control port',
    'the Karmashala host on SSH machines (its server refuses them)',
  ];
}

/// The probe switch for everything holding a [Ref]. Defaults to
/// [ProbeMode.current], so a container nobody overrode is still guarded.
final probeModeProvider = Provider<ProbeMode>((ref) => ProbeMode.current);

/// Why a probe refused to start. The message is shown on the failure screen.
class ProbeDataDirectoryError extends StateError {
  ProbeDataDirectoryError(super.message);
}

/// Decides where the data folder is — the database, logs, sockets and the MCP
/// handshake — and **refuses** a probe that would share the real one.
///
/// A probe without `KARMASHALA_DATA_DIR` is refused rather than given a scratch
/// folder: child processes inherit the variable, and the MCP bridge an agent
/// inside the probe spawns finds its handshake through it. A folder chosen
/// here would leave those agents calling the real app's tools.
Future<Directory> resolveDataDirectory({
  required ProbeMode probe,
  required Future<Directory> Function() platformDefault,
}) async {
  final override = probe.dataDirectory;
  if (override == null) {
    if (probe.enabled) {
      throw ProbeDataDirectoryError(
        '$kProbeEnvironmentVariable is set but $kDataDirectoryEnvironmentVariable '
        'is not. A probe must have its own data folder, or it would open the '
        'real Karmashala database. Set $kDataDirectoryEnvironmentVariable to a '
        'scratch folder, for example:\n'
        '  \$env:$kDataDirectoryEnvironmentVariable = '
        '"\$env:TEMP\\karmashala-probe"',
      );
    }
    return platformDefault();
  }
  final dir = Directory(override);
  if (probe.enabled) {
    final real = await platformDefault();
    if (sameDirectory(dir.path, real.path)) {
      throw ProbeDataDirectoryError(
        '$kDataDirectoryEnvironmentVariable points at the real Karmashala data '
        'folder (${real.path}). A probe must use a different folder.',
      );
    }
  }
  await dir.create(recursive: true);
  return dir;
}

/// Whether [a] and [b] name one directory, ignoring case where the file system
/// does and trailing separators everywhere. Links are not followed: the real
/// folder is never a link, and resolving one would need it to exist.
bool sameDirectory(String a, String b, {bool? caseInsensitive}) {
  String normal(String path) {
    final n = p.normalize(p.absolute(path));
    return (caseInsensitive ?? Platform.isWindows) ? n.toLowerCase() : n;
  }

  return normal(a) == normal(b);
}
