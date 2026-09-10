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

/// Binaries named `karmashala_host-<version>-<os>-<arch>`. Only linux-x64 and
/// arm64 exist: the Windows Dart SDK refuses `--target-os=macos` outright.
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
      // Every version ever installed accumulates here, so the newest is what
      // this build means; a stale pick reads as `protocolMismatch`.
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

  /// Compares two filename versions segment by segment, as numbers: a string
  /// sort puts `1.9.0` above `1.20.1`, which is the whole bug.
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
