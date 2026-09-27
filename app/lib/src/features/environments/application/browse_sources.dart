import 'package:agent_cli/process.dart';
import 'package:karmashala_ui/picking.dart';
import 'package:riverpod/riverpod.dart';

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
  return [
    for (final environment in container.read(environmentsControllerProvider))
      if (_browsable(environment))
        BrowseSource(
          id: environment.id,
          label:
              environmentLabel(environment) ??
              (_isLocal(environment) ? 'This computer' : environment.name),
          // This machine's own drives and folders are worth offering as
          // shortcuts only when the server's disk is this machine's.
          local: _isLocal(environment) && files.serverOnThisMachine,
          home: () async => (await files.home(environment.id)).path,
          lister: (path) => _list(files, environment.id, path),
        ),
  ];
}

bool _isLocal(ExecutionEnvironment environment) =>
    environment.kind == EnvironmentKind.windowsNative ||
    environment.kind == EnvironmentKind.localPosix;

bool _browsable(ExecutionEnvironment environment) =>
    switch (environment.kind) {
      EnvironmentKind.windowsNative || EnvironmentKind.localPosix => true,
      EnvironmentKind.wsl => environment.wslDistribution != null,
      EnvironmentKind.ssh => environment.sshHostId != null,
    };

Future<List<BrowsedEntry>> _list(
  FilesClient files,
  String environmentId,
  String path,
) async {
  final entries = await files.list(
    EnvironmentPath(environmentId: environmentId, path: path),
  );
  return [
    for (final entry in entries)
      BrowsedEntry(
        name: entry.name,
        path: entry.path.path,
        isDirectory: entry.isDirectory,
        hidden: entry.isHidden,
      ),
  ];
}
