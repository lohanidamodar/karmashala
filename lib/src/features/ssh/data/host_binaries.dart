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

  /// Searched in order; the first match wins.
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
      for (final entity in directory.listSync().whereType<File>()) {
        final match = _name.firstMatch(entity.uri.pathSegments.last);
        if (match == null) continue;
        if ('${match.group(2)}-${match.group(3)}' != platform.targetKey) continue;
        return HostBinary(
          bytes: await entity.readAsBytes(),
          version: match.group(1) ?? 'unversioned',
          source: entity.path,
        );
      }
    }
    return null;
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
