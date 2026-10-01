import 'package:agent_cli/process.dart';
import 'package:karmashala_files/values.dart' show FileEntry, FileEntryKind;
import 'package:karmashala_ui/picking.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/capabilities/capabilities.dart';
import '../../files/data/files_client.dart';
import 'environments_controller.dart';

/// Every machine a "Browse…" may look at, built from the environments this
/// workspace has discovered, each listed by the server (slice 3c) — so a
/// project root, an executable or an SSH key is picked where the server will
/// use it, even when that is not this machine.
///
/// Each source answers in **its own** spelling — a Windows path here, a POSIX
/// path in a distribution or on a host — because that is what a project root,
/// an executable path and an SSH key are stored as. Nothing is translated.
List<BrowseSource> browseSourcesFrom(ProviderContainer container) {
  final files = container.read(filesClientProvider);
  final readsServerDisk = container.read(capabilitiesProvider).readsServerDisk;
  return [
    for (final environment in container.read(environmentsControllerProvider))
      if (isBrowsableEnvironment(environment))
        browseSourceFor(files, environment, readsServerDisk: readsServerDisk),
  ];
}

/// One machine as a browser's source: listed, resolved and written by the
/// server. [seen], when given, is told every entry listed, by path — for a
/// caller whose verbs need the server's own [FileEntry] (the Files tab).
BrowseSource browseSourceFor(
  FilesClient files,
  ExecutionEnvironment environment, {
  required bool readsServerDisk,
  void Function(FileEntry entry)? seen,
}) {
  final id = environment.id;
  EnvironmentPath at(String path) =>
      EnvironmentPath(environmentId: id, path: path);
  return BrowseSource(
    id: id,
    label:
        environmentLabel(environment) ??
        (_isLocal(environment) ? 'This computer' : environment.name),
    // This machine's own drives and folders are worth offering as shortcuts
    // only when the server's disk is this machine's.
    local: _isLocal(environment) && readsServerDisk,
    home: () async => (await files.home(id)).path,
    lister: (path) async {
      final entries = await files.list(at(path));
      if (seen != null) {
        for (final entry in entries) {
          seen(entry);
        }
      }
      return [for (final entry in entries) _browsed(entry)];
    },
    resolve: (path) async => (await files.resolve(at(path))).path.path,
    createDirectory: (directory, name) async =>
        (await files.createDirectory(at(directory), name)).path,
    createFile: (directory, name) async =>
        (await files.createFile(at(directory), name)).path,
  );
}

BrowsedEntry _browsed(FileEntry entry) => BrowsedEntry(
  name: entry.name,
  path: entry.path.path,
  isDirectory: entry.isDirectory,
  hidden: entry.isHidden,
  isLink: entry.kind == FileEntryKind.symlink,
  sizeBytes: entry.sizeBytes,
);

/// Whether a file browser can show [environment]: this machine always, a
/// distribution or host once it names one.
bool isBrowsableEnvironment(ExecutionEnvironment environment) =>
    switch (environment.kind) {
      EnvironmentKind.windowsNative || EnvironmentKind.localPosix => true,
      EnvironmentKind.wsl => environment.wslDistribution != null,
      EnvironmentKind.ssh => environment.sshHostId != null,
    };

bool _isLocal(ExecutionEnvironment environment) =>
    environment.kind == EnvironmentKind.windowsNative ||
    environment.kind == EnvironmentKind.localPosix;
