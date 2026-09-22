import 'package:agent_cli/process.dart';
import 'package:karmashala_ssh/files.dart';
import 'package:riverpod/riverpod.dart';

import '../../environments/application/environment_providers.dart';
import '../../ssh/application/ssh_providers.dart';
import '../data/local_document_source.dart';
import '../data/sftp_document_source.dart';
import '../domain/document_source.dart';

/// Every environment the editor can open files in: this machine and WSL over
/// `dart:io`, an SSH host over SFTP on the pooled connection. One source per
/// environment for the app's life, because documents outlive the panels that
/// opened them — unlike a Files panel's space, closed with its widget.
class AppDocumentSources implements DocumentSourceResolver {
  AppDocumentSources(this._ref);

  final Ref _ref;
  final LocalDocumentSources _local = LocalDocumentSources();
  final Map<String, DocumentSource> _remote = {};

  @override
  DocumentSource? sourceFor(String environmentId) {
    final local = _local.sourceFor(environmentId);
    if (local != null) return local;
    final cached = _remote[environmentId];
    if (cached != null) return cached;
    final environment = _ref
        .read(executionEnvironmentDaoProvider)
        .getById(environmentId);
    if (environment == null) return null;
    final source = switch (environment.kind) {
      // A local POSIX row under another id is still this machine's disk.
      EnvironmentKind.windowsNative ||
      EnvironmentKind.localPosix => _local.sourceFor(localHostEnvironmentId),
      EnvironmentKind.wsl => null,
      EnvironmentKind.ssh => _sftp(environment),
    };
    if (source != null) _remote[environmentId] = source;
    return source;
  }

  DocumentSource? _sftp(ExecutionEnvironment environment) {
    final hostId = environment.sshHostId;
    if (hostId == null) return null;
    final RemoteFileBrowser browser;
    try {
      browser = RemoteFileBrowser(
        connection: _ref.read(sshConnectionPoolProvider).forHostId(hostId),
        environmentId: environment.id,
      );
    } on ArgumentError {
      // The host was deleted while a tab still named it.
      return null;
    }
    return SftpDocumentSource(browser, onClose: browser.close);
  }

  Future<void> close() async {
    final open = _remote.values.toList();
    _remote.clear();
    for (final source in open) {
      await source.close();
    }
  }
}

final documentSourcesProvider = Provider<DocumentSourceResolver>((ref) {
  final sources = AppDocumentSources(ref);
  ref.onDispose(sources.close);
  return sources;
});
