import 'dart:async';
import 'dart:convert';

import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import '../../repositories/application/repository_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../data/local_document_source.dart';
import '../domain/document_id.dart';
import 'open_documents.dart';

/// The argument keys a file tool names its file under: Claude Code's
/// `Write`/`Edit`/`MultiEdit` (`file_path`), `NotebookEdit` (`notebook_path`),
/// and the generic `path`.
const Set<String> _fileKeys = {'file_path', 'notebook_path', 'path'};

/// A Codex `apply_patch` names each file on a header line of the patch text.
final RegExp _patchHeader = RegExp(
  r'^\*\*\* (?:Update|Add|Delete) File: (.+?)\s*$|^\*\*\* Move to: (.+?)\s*$',
  multiLine: true,
);

/// The paths [toolInput] says a tool touched, as the agent spelled them.
Set<String> toolInputPaths(Object? toolInput) {
  final paths = <String>{};
  if (toolInput is! Map) return paths;
  for (final MapEntry(:key, :value) in toolInput.entries) {
    if (value is! String || value.isEmpty) continue;
    if (_fileKeys.contains(key)) paths.add(value.trim());
    if (value.contains('*** ')) {
      for (final match in _patchHeader.allMatches(value)) {
        final path = match.group(1) ?? match.group(2);
        if (path != null && path.isNotEmpty) paths.add(path);
      }
    }
  }
  return paths;
}

/// Whether [agentPath] could name the file open at [hostPath].
///
/// Matched by spelling rather than translated through the session's
/// environment: a hook may come from a session this app has no row for, and a
/// wrong guess costs one stat. A WSL path is the tail of its UNC spelling
/// (`\\wsl.localhost\<distro>\home\…`), `/mnt/c/…` and `/c/…` are `C:\…`, and
/// a relative path is a tail too.
bool hostPathNamedBy(String hostPath, String agentPath) {
  final host = _normal(hostPath);
  var named = _normal(agentPath);
  final drive = RegExp(r'^/(?:mnt/)?([a-z])/').firstMatch(named);
  if (drive != null) {
    named = '${drive.group(1)}:/${named.substring(drive.end)}';
  }
  if (named.isEmpty) return false;
  if (host == named) return true;
  return host.endsWith(named.startsWith('/') ? named : '/$named');
}

String _normal(String path) {
  var normal = path.trim().replaceAll(r'\', '/').toLowerCase();
  while (normal.startsWith('./')) {
    normal = normal.substring(2);
  }
  return normal;
}

/// Whether [agentPath], from a session in [sessionEnvironmentId] (null: not
/// known), could name the open document [documentId].
///
/// A file this desktop can reach is matched by its host spelling, as
/// [hostPathNamedBy] does. A file on an SSH host has none: it is named by its
/// POSIX path — whole, or a relative tail — and only by a session on that same
/// host when the session's environment is known.
bool documentNamedBy(
  String documentId,
  String agentPath, {
  String? sessionEnvironmentId,
}) {
  final host = hostPathOfDocument(documentId);
  if (host != null) return hostPathNamedBy(host, agentPath);
  final at = documentPathOf(documentId);
  if (sessionEnvironmentId != null &&
      sessionEnvironmentId != at.environmentId) {
    return false;
  }
  var named = agentPath.trim();
  while (named.startsWith('./')) {
    named = named.substring(2);
  }
  if (named.isEmpty) return false;
  if (named == at.path) return true;
  return !named.startsWith('/') && at.path.endsWith('/$named');
}

/// The open documents one hook callback should re-check. A tool that named
/// files re-checks the open ones among them; a tool that named none (a shell
/// command that ran `sed -i`) and a finished turn re-check everything open.
/// [sessionEnvironmentId] is where the hook's session runs, when known.
List<String> openPathsToCheck({
  required String? event,
  required String body,
  required List<String> toolInputPath,
  required Iterable<String> openPaths,
  String? sessionEnvironmentId,
}) {
  final open = openPaths.toList();
  if (open.isEmpty) return const [];
  if (event == 'Stop' || event == 'SubagentStop') return open;
  if (event != 'PostToolUse') return const [];
  Object? input;
  try {
    input = jsonDecode(body);
  } on FormatException {
    return const [];
  }
  for (final segment in toolInputPath) {
    input = input is Map ? input[segment] : null;
  }
  final named = toolInputPaths(input);
  if (named.isEmpty) return open;
  return [
    for (final id in open)
      if (named.any(
        (path) => documentNamedBy(
          id,
          path,
          sessionEnvironmentId: sessionEnvironmentId,
        ),
      ))
        id,
  ];
}

/// Re-checks, against the disk, the open editor buffers an agent hook says a
/// tool may have just written — so an agent's edit shows now rather than at
/// the next poll. Never throws; a container with no editor open does nothing.
void checkEditorFilesFromHook(
  ProviderContainer container, {
  required String agentId,
  required String? event,
  required String body,
  String? agentSessionId,
}) {
  if (!container.exists(openDocumentsProvider)) return;
  final open = container.read(openDocumentsProvider).keys;
  if (open.isEmpty) return;
  final spec = container.read(agentRegistryProvider).byId(agentId)?.hooks;
  final paths = openPathsToCheck(
    event: event,
    body: body,
    toolInputPath: spec?.toolInputPath ?? const ['tool_input'],
    openPaths: open,
    sessionEnvironmentId: open.any((id) => hostPathOfDocument(id) == null)
        ? _sessionEnvironment(container, agentSessionId)
        : null,
  );
  final documents = container.read(openDocumentsProvider.notifier);
  for (final path in paths) {
    unawaited(documents.checkOnDisk(path));
  }
}

/// The environment the session [agentSessionId] works in, from its checkout's
/// row; null when there is no such session. Asked only when an SSH document
/// is open, so a hook with no remote file open reads nothing.
String? _sessionEnvironment(
  ProviderContainer container,
  String? agentSessionId,
) {
  if (agentSessionId == null || agentSessionId.isEmpty) return null;
  try {
    final session = container
        .read(sessionDaoProvider)
        .getByExternalSessionId(agentSessionId);
    if (session == null) return null;
    return container
        .read(repositoryDaoProvider)
        .getById(session.repositoryId)
        ?.path
        .environmentId;
  } on Object {
    // A guess costs one stat; failing to guess costs nothing.
    return null;
  }
}
