import 'dart:io';

import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/process.dart';
import 'package:karmashala_ssh/files.dart';
import 'package:karmashala_ui/picking.dart';

import '../../ssh/application/ssh_hosts_controller.dart';
import '../../ssh/application/ssh_providers.dart';
import 'environments_controller.dart';

/// Every machine a "Browse…" may look at, built from the environments this
/// workspace has discovered.
///
/// Each source answers in **its own** spelling — a Windows path here, a POSIX
/// path in a distribution or on a host — because that is what a project root,
/// an executable path and an SSH key are stored as. Nothing is translated on
/// the way out; only the *reading* of a WSL directory goes over the share.
List<BrowseSource> browseSourcesFrom(ProviderContainer container) {
  final environments = container.read(environmentsControllerProvider);
  final sources = <BrowseSource>[];

  for (final environment in environments) {
    switch (environment.kind) {
      case EnvironmentKind.windowsNative:
      case EnvironmentKind.localPosix:
        sources.add(
          BrowseSource(
            id: environment.id,
            label: environmentLabel(environment) ?? 'This computer',
            local: true,
            home: () async => _localHome(),
            lister: listDirectory,
          ),
        );
      case EnvironmentKind.wsl:
        final distribution = environment.wslDistribution;
        if (distribution == null) continue;
        sources.add(
          BrowseSource(
            id: environment.id,
            label: environmentLabel(environment) ?? distribution,
            // `/home` rather than a guess at the user's own folder: one tap in
            // beats a path that is wrong on a distribution with another login.
            home: () async => '/home',
            lister: (path) => _listWslDirectory(distribution, path),
          ),
        );
      case EnvironmentKind.ssh:
        final hostId = environment.sshHostId;
        if (hostId == null) continue;
        sources.add(
          BrowseSource(
            id: environment.id,
            label: environmentLabel(environment) ?? environment.name,
            home: () => _sshHome(container, environment, hostId),
            lister: (path) =>
                _listSshDirectory(container, environment, hostId, path),
          ),
        );
    }
  }
  return sources;
}

String _localHome() =>
    Platform.environment['USERPROFILE'] ??
    Platform.environment['HOME'] ??
    (Platform.isWindows ? r'C:\' : '/');

/// A distribution's directory, read over `\\wsl.localhost` — measured at under
/// a millisecond warm (§18), against interop's ~72 ms per spawn. The entries
/// come back in **POSIX** spelling, so nothing above this sees a UNC path.
Future<List<BrowsedEntry>> _listWslDirectory(
  String distribution,
  String posixPath,
) async {
  final share = _uncFor(distribution, posixPath);
  final base = posixPath.replaceAll(RegExp(r'/+$'), '');
  final entries = <BrowsedEntry>[];
  await for (final entity in Directory(share).list(followLinks: false)) {
    final name = _leafOf(entity.path);
    entries.add(
      BrowsedEntry(
        name: name,
        path: base.isEmpty ? '/$name' : '$base/$name',
        isDirectory: entity is Directory,
        // The share carries no Windows attributes worth trusting, and a
        // distribution's own convention is the leading dot.
        hidden: name.startsWith('.'),
      ),
    );
  }
  return entries;
}

String _uncFor(String distribution, String posixPath) {
  final trimmed = posixPath.replaceAll(RegExp(r'^/+'), '');
  final tail = trimmed.replaceAll('/', r'\');
  final root = r'\\wsl.localhost\' + distribution;
  return tail.isEmpty ? root : '$root\\$tail';
}

Future<String> _sshHome(
  ProviderContainer container,
  ExecutionEnvironment environment,
  String hostId,
) async {
  final host = container
      .read(sshHostsControllerProvider)
      .where((h) => h.id == hostId)
      .firstOrNull;
  final browser = _browserFor(container, environment, hostId);
  final configured = host?.defaultDirectory?.path;
  if (configured != null && configured.trim().isNotEmpty) return configured;
  return (await browser.home()).path;
}

Future<List<BrowsedEntry>> _listSshDirectory(
  ProviderContainer container,
  ExecutionEnvironment environment,
  String hostId,
  String path,
) async {
  final browser = _browserFor(container, environment, hostId);
  final entries = await browser.list(
    EnvironmentPath(environmentId: environment.id, path: path),
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

/// A browser on the pooled connection. Not cached here: the pool already keeps
/// the connection up, and an SFTP channel per listing is what the side panel's
/// own browser costs.
RemoteFileBrowser _browserFor(
  ProviderContainer container,
  ExecutionEnvironment environment,
  String hostId,
) => RemoteFileBrowser(
  connection: container.read(sshConnectionPoolProvider).forHostId(hostId),
  environmentId: environment.id,
);

String _leafOf(String path) {
  final cleaned = path.replaceAll(RegExp(r'[\\/]+$'), '');
  final cut = cleaned.lastIndexOf(RegExp(r'[\\/]'));
  return cut == -1 ? cleaned : cleaned.substring(cut + 1);
}
