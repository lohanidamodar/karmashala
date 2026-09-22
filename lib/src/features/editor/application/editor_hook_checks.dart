import 'dart:async';
import 'dart:convert';

import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
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

/// The open host paths one hook callback should re-check. A tool that named
/// files re-checks the open ones among them; a tool that named none (a shell
/// command that ran `sed -i`) and a finished turn re-check everything open.
List<String> openPathsToCheck({
  required String? event,
  required String body,
  required List<String> toolInputPath,
  required Iterable<String> openPaths,
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
    for (final hostPath in open)
      if (named.any((path) => hostPathNamedBy(hostPath, path))) hostPath,
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
  );
  final documents = container.read(openDocumentsProvider.notifier);
  for (final path in paths) {
    unawaited(documents.checkOnDisk(path));
  }
}
