import 'dart:io';


import '../domain/host_deployment.dart';

/// Where the host binaries come from on this machine.
abstract class HostBinarySource {
  /// Null when this build ships nothing for [platform]. The deployer reports
  /// that as `noBinary` rather than trying and failing on the far end.
  Future<HostBinary?> binaryFor(HostPlatform platform);

  /// Every target this build could serve, for a message that says what it has.
  Future<List<String>> availableTargets();
}

/// Binaries named `karmashala_host-<version>-<os>-<arch>`.
///
/// In a release they sit beside `karmashala.exe` and `karmashala_mcp.exe` —
/// `tool/build_release.bat` cross-compiles them into the Release directory the
/// installer copies wholesale, so no installer change is needed. In a debug run
/// they come from `host/build/`, which is what `dart compile exe` writes.
///
/// Only linux-x64 and linux-arm64 exist. The Windows Dart SDK's `compile exe`
/// refuses `--target-os=macos` outright — measured 2026-09-08, it answers
/// "Unsupported target platform macos_arm64. Supported target platforms:
/// linux_arm, linux_arm64, linux_riscv64, linux_x64" — so a macOS host has no
/// binary and falls back to tmux, and it is this class that knows it.
class DirectoryHostBinaries implements HostBinarySource {
  DirectoryHostBinaries(this.directories);

  /// Searched in order; the first directory holding a match wins, and within it
  /// the highest version does.
  final List<Directory> directories;

  /// Beside the running executable first, then the repository's build output,
  /// so a debug run picks up what was just compiled.
  factory DirectoryHostBinaries.standard({
    String? executableDirectory,
    String? repositoryRoot,
  }) {
    final beside = executableDirectory ?? File(Platform.resolvedExecutable).parent.path;
    return DirectoryHostBinaries([
      Directory(beside),
      Directory('${repositoryRoot ?? Directory.current.path}/host/build'),
    ]);
  }

  static final _name = RegExp(r'^karmashala_host-(?:([0-9][^-]*)-)?([a-z]+)-([a-z0-9]+)$');

  @override
  Future<HostBinary?> binaryFor(HostPlatform platform) async {
    for (final directory in directories) {
      if (!directory.existsSync()) continue;
      final candidates = <(String?, File)>[];
      for (final entity in directory.listSync().whereType<File>()) {
        final match = _name.firstMatch(entity.uri.pathSegments.last);
        if (match == null) continue;
        if ('${match.group(2)}-${match.group(3)}' != platform.targetKey) continue;
        candidates.add((match.group(1), entity));
      }
      if (candidates.isEmpty) continue;
      // Every version ever installed accumulates here — the installer copies
      // the Release directory wholesale and nothing prunes it — so the newest
      // is what this build means, not whichever the filesystem listed first.
      // On 2026-09-10 that took 1.20.0 while 1.20.1 lay beside it, and a stale
      // pick reads as `protocolMismatch` after a protocol bump. The older files
      // are left exactly where they are.
      candidates.sort((a, b) => compareFilenameVersions(b.$1, a.$1));
      final (version, file) = candidates.first;
      return HostBinary(
        bytes: await file.readAsBytes(),
        version: version ?? 'unversioned',
        source: file.path,
        candidates: candidates.length,
      );
    }
    return null;
  }

  /// Compares two filename versions segment by segment, as numbers.
  ///
  /// A string sort puts `1.9.0` above `1.20.1`, which is the whole bug. `null`
  /// is a file the regex matched without a version and is lowest — it says
  /// nothing about what it is, so it loses to anything that does. Segments that
  /// are not plain integers (a `+build` tail) fall back to comparing the text,
  /// which is a tie-break rather than an ordering claim.
  static int compareFilenameVersions(String? a, String? b) {
    if (a == null || b == null) return (a == null ? 0 : 1) - (b == null ? 0 : 1);
    final left = a.split('.');
    final right = b.split('.');
    for (var i = 0; i < left.length || i < right.length; i++) {
      final l = i < left.length ? left[i] : '0';
      final r = i < right.length ? right[i] : '0';
      final ln = int.tryParse(l);
      final rn = int.tryParse(r);
      final order = ln != null && rn != null ? ln.compareTo(rn) : l.compareTo(r);
      if (order != 0) return order;
    }
    return 0;
  }

  @override
  Future<List<String>> availableTargets() async {
    final found = <String>{};
    for (final directory in directories) {
      if (!directory.existsSync()) continue;
      for (final entity in directory.listSync().whereType<File>()) {
        final match = _name.firstMatch(entity.uri.pathSegments.last);
        if (match != null) found.add('${match.group(2)}-${match.group(3)}');
      }
    }
    return found.toList()..sort();
  }
}
