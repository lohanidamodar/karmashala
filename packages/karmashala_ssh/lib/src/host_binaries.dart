import 'dart:io';

import 'host_deployment.dart';

/// Where the host binaries come from on this machine.
abstract class HostBinarySource {
  /// Null when this build ships nothing for [platform]. The deployer reports
  /// that as `noBinary` rather than trying and failing on the far end.
  Future<HostBinary?> binaryFor(HostPlatform platform);

  /// Every target this build could serve, for a message that says what it has.
  Future<List<String>> availableTargets();
}

/// Binaries named `karmashala_host-<version>-<os>-<arch>`, with or without a
/// `.tar.gz` suffix. Only linux-x64 and arm64 exist: the Windows Dart SDK
/// refuses `--target-os=macos` outright.
///
/// The tarball is a `dart build cli` bundle — the executable beside the SQLite
/// it was built with — and is what every current build ships. A bare file is a
/// host from before the store and is still accepted, so an installation that
/// has not been rebuilt keeps working.
class DirectoryHostBinaries implements HostBinarySource {
  DirectoryHostBinaries(this.directories);

  /// Searched in order; the first directory holding a match wins, and within it
  /// the highest version does.
  final List<Directory> directories;

  /// Beside the running executable first, then the repository's build output,
  /// so a debug run picks up what was just compiled.
  factory DirectoryHostBinaries.standard({String? executableDirectory, String? repositoryRoot}) {
    final beside = executableDirectory ?? File(Platform.resolvedExecutable).parent.path;
    return DirectoryHostBinaries([
      Directory(beside),
      // `packages/` since f94086f7 moved the host there; this said `host/build`
      // and had been naming a directory that cannot exist.
      Directory('${repositoryRoot ?? Directory.current.path}/packages/host/build'),
    ]);
  }

  static final _name = RegExp(
    r'^karmashala_host-(?:([0-9][^-]*)-)?([a-z]+)-([a-z0-9]+)(\.tar\.gz)?$',
  );

  @override
  Future<HostBinary?> binaryFor(HostPlatform platform) async {
    for (final directory in directories) {
      if (!directory.existsSync()) continue;
      final candidates = <(String?, bool, File)>[];
      for (final entity in directory.listSync().whereType<File>()) {
        final match = _name.firstMatch(entity.uri.pathSegments.last);
        if (match == null) continue;
        if ('${match.group(2)}-${match.group(3)}' != platform.targetKey) continue;
        candidates.add((match.group(1), match.group(4) != null, entity));
      }
      if (candidates.isEmpty) continue;
      // **Shape first, then version.** Every version ever installed accumulates
      // here — the installer deletes nothing — so a release whose Linux bundles
      // were not published yet leaves only a *bare* file from an older install,
      // and ranking by version would deploy a pre-store host that answers
      // `hello` and reads as `ready`. A bundle at any version can hold a store
      // and a bare file at any version cannot, so the bundle wins outright; the
      // newest of the same shape wins after that.
      candidates.sort((a, b) {
        final byShape = (b.$2 ? 1 : 0) - (a.$2 ? 1 : 0);
        if (byShape != 0) return byShape;
        return compareFilenameVersions(b.$1, a.$1);
      });
      final (version, isArchive, file) = candidates.first;
      return HostBinary(
        // The size, not the bytes: the deployer compares it against the remote
        // `wc -c` and returns without uploading when they match, which is the
        // steady state. Reading tens of megabytes to discard them is the cost
        // of every deploy and every reconnect.
        length: file.lengthSync(),
        readBytes: file.readAsBytes,
        version: version ?? 'unversioned',
        source: file.path,
        isBundleArchive: isArchive,
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
