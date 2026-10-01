import 'dart:io';

import 'package:karmashala_ssh_host/host.dart';
import 'package:path/path.dart' as p;

/// Names more folders the server reads host bundles from, before its own
/// (the OS's path-list separator between them): where an operator keeps the
/// bundles for the boxes a standalone server deploys to.
const String kHostBundlesVariable = 'KARMASHALA_HOST_BUNDLES';

/// **Where the server finds the host bundles it deploys to SSH boxes**
/// (slice 5d) — `karmashala_host-<version>-<os>-<arch>.tar.gz`, one per box
/// platform (linux-x64, linux-arm64, and a Mac's own). Never the client's
/// app bundle: the server deploys, so the server looks, in order:
///
/// 1. every folder in `KARMASHALA_HOST_BUNDLES`;
/// 2. `<data dir>/host-bundles` — where a standalone server's operator puts
///    them;
/// 3. beside the server's own bundle: the bundle folder itself (`<bundle>`,
///    the server running as `<bundle>/bin/karmashala_host`) and the folder
///    holding it — in a desktop release that is where the build puts them
///    (`Karmashala.app/Contents/MacOS/`, the Windows install folder);
/// 4. the repository's `server/build`, found by walking up from the working
///    folder — so a debug run (`dart run`, a test) finds what was just built.
///
/// A box whose bundle is in none of them is refused in words that name these
/// folders (`HostDeployer`'s `noBinary`); there is no fallback.
HostBinarySource serverHostBundles({
  required String dataDirectory,
  Map<String, String>? environment,
  String? executable,
  String? workingDirectory,
}) {
  final env = environment ?? Platform.environment;
  final folders = <String>[];
  void add(String folder) {
    final normal = p.normalize(p.absolute(folder));
    if (!folders.contains(normal)) folders.add(normal);
  }

  final named = env[kHostBundlesVariable];
  if (named != null) {
    for (final folder in named.split(Platform.isWindows ? ';' : ':')) {
      if (folder.trim().isNotEmpty) add(folder.trim());
    }
  }
  final dropFolder = p.normalize(p.absolute(dataDirectory, 'host-bundles'));
  add(dropFolder);
  final self = executable ?? Platform.resolvedExecutable;
  final bin = p.dirname(self);
  if (p.basename(bin) == 'bin') {
    final bundle = p.dirname(bin);
    add(bundle);
    add(p.dirname(bundle));
  }
  var probe = Directory(workingDirectory ?? Directory.current.path).absolute;
  for (var i = 0; i < 6; i++) {
    if (File(p.join(probe.path, 'server', 'pubspec.yaml')).existsSync()) {
      add(p.join(probe.path, 'server', 'build'));
      break;
    }
    if (p.basename(probe.path) == 'server' &&
        File(p.join(probe.path, 'pubspec.yaml')).existsSync()) {
      add(p.join(probe.path, 'build'));
      break;
    }
    final parent = probe.parent;
    if (parent.path == probe.path) break;
    probe = parent;
  }
  return DirectoryHostBinaries([
    for (final folder in folders) Directory(folder),
  ], dropFolder: dropFolder);
}
