import 'dart:io';
import 'package:karmashala_host_protocol/host_access.dart';
import 'package:karmashala_host_protocol/protocol.dart' show kHostVersion;

import 'host_deployment.dart';

/// Where the host bundles for other machines come from, on the machine that
/// deploys them (the server's, slice 5d).
abstract class HostBinarySource {
  /// Null when there is nothing for [platform]. The deployer reports that as
  /// `noBinary` rather than trying and failing on the far end.
  Future<HostBinary?> binaryFor(HostPlatform platform);

  /// Every target there is a bundle for, for a message that says what it has.
  Future<List<String>> availableTargets();

  /// Where it looked, in words, for a refusal a person can act on.
  String describeSearch();

  /// The folder an operator puts a bundle into, for a remedy that names one.
  /// Read on every call, so a bundle put there is found without a restart.
  String? get dropFolder;
}

/// Binaries named `karmashala_host-<version>-<os>-<arch>`, with or without a
/// `.tar.gz` suffix: linux-x64 and linux-arm64, and from a macOS build the
/// Mac's own architecture — no SDK cross-builds for macOS.
///
/// The tarball is a `dart build cli` bundle — the executable beside the SQLite
/// it was built with — and is what every current build ships. A bare file is a
/// host from before the store and is still accepted, so an installation that
/// has not been rebuilt keeps working.
class DirectoryHostBinaries implements HostBinarySource {
  DirectoryHostBinaries(
    this.directories, {
    this.dropFolder,
    this.preferredVersion = kHostVersion,
  });

  /// Every one is searched, and the best match across all of them wins: see
  /// [binaryFor]. Their order only breaks a tie between equal versions.
  final List<Directory> directories;

  /// The version a match is preferred at over any newer one: the server's own
  /// host, which speaks its protocol.
  final String preferredVersion;

  @override
  final String? dropFolder;

  @override
  String describeSearch() => directories.isEmpty
      ? 'nowhere: no folder was named'
      : directories.map((d) => d.path).join(', ');

  static final _name = RegExp(
    r'^karmashala_host-(?:([0-9][^-]*)-)?([a-z]+)-([a-z0-9]+)(\.tar\.gz)?$',
  );

  @override
  Future<HostBinary?> binaryFor(HostPlatform platform) async {
    // **Every folder, then one ranking.** Taking the first folder with any
    // match let an operator's drop folder holding an earlier release's bundle
    // shadow the install folder's current one, and every reinstall put the old
    // host back.
    final candidates = <_Candidate>[];
    for (final (index, directory) in directories.indexed) {
      if (!directory.existsSync()) continue;
      for (final entity in directory.listSync().whereType<File>()) {
        final match = _name.firstMatch(entity.uri.pathSegments.last);
        if (match == null) continue;
        if ('${match.group(2)}-${match.group(3)}' != platform.targetKey) {
          continue;
        }
        candidates.add(
          _Candidate(match.group(1), match.group(4) != null, entity, index),
        );
      }
    }
    if (candidates.isEmpty) return null;
    // **Shape first.** Every version ever installed accumulates — the installer
    // deletes nothing — so a release whose Linux bundles were not published
    // yet leaves only a *bare* file from an older install, and ranking by
    // version would deploy a pre-store host that answers `hello` and reads as
    // `ready`. A bundle at any version can hold a store and a bare file at any
    // version cannot, so the bundle wins outright. Then the server's own
    // version, which speaks its protocol; then the newest; then folder order,
    // so an operator's folder wins between equal versions.
    candidates.sort((a, b) {
      final byShape = (b.isArchive ? 1 : 0) - (a.isArchive ? 1 : 0);
      if (byShape != 0) return byShape;
      final byPreference =
          (b.version == preferredVersion ? 1 : 0) -
          (a.version == preferredVersion ? 1 : 0);
      if (byPreference != 0) return byPreference;
      final byVersion = compareHostVersions(b.version, a.version);
      if (byVersion != 0) return byVersion;
      return a.folder - b.folder;
    });
    final chosen = candidates.first;
    final file = chosen.file;
    // A folder searched first whose every match is older than the one taken.
    String? olderIn;
    for (var index = 0; index < chosen.folder && olderIn == null; index++) {
      final here = candidates.where((c) => c.folder == index);
      if (here.isNotEmpty &&
          here.every(
            (c) => compareHostVersions(c.version, chosen.version) < 0,
          )) {
        olderIn = directories[index].path;
      }
    }
    return HostBinary(
      // The size, not the bytes: the deployer compares it against the remote
      // `wc -c` and returns without uploading when they match, which is the
      // steady state. Reading tens of megabytes to discard them is the cost
      // of every deploy and every reconnect.
      length: file.lengthSync(),
      readBytes: file.readAsBytes,
      version: chosen.version ?? 'unversioned',
      source: file.path,
      isBundleArchive: chosen.isArchive,
      candidates: candidates.length,
      folder: directories[chosen.folder].path,
      olderBundlesIn: olderIn,
    );
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

/// One matching file, and the index of the folder it was found in.
class _Candidate {
  _Candidate(this.version, this.isArchive, this.file, this.folder);

  final String? version;
  final bool isArchive;
  final File file;
  final int folder;
}
