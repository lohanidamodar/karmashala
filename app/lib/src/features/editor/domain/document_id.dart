/// How an open file is named: the environment it lives in and its path in that
/// environment's own spelling — an [EnvironmentPath] — written as one string so
/// it can key a buffer and ride inside a pane id.
library;

import 'package:agent_cli/process.dart';
import 'package:path/path.dart' as p;

/// Separates the environment from the path. The same separator pane ids use,
/// because no path can contain it.
const String _separator = '␟';

/// A share path into a WSL distribution, as every document id was spelled
/// before ids carried their environment: `\\wsl.localhost\<distro>\…` or the
/// older `\\wsl$\<distro>\…`.
final RegExp _wslShare = RegExp(
  r'^\\\\(?:wsl\.localhost|wsl\$)\\([^\\]+)(\\.*)?$',
  caseSensitive: false,
);

/// The id of the document at [path]. This machine's files keep their bare path
/// — the id every tab persisted before environments were part of it — and
/// anything elsewhere is `<environment>␟<path>`.
String documentIdOf(EnvironmentPath path) =>
    path.environmentId == localHostEnvironmentId
    ? path.path
    : '${path.environmentId}$_separator${path.path}';

/// The file [documentId] names. A bare `\\wsl.localhost\<distro>\…` id, from a
/// tab saved before ids carried their environment, is read as that
/// distribution's POSIX path, so it and a fresh open are the same document.
EnvironmentPath documentPathOf(String documentId) {
  final cut = documentId.indexOf(_separator);
  if (cut > 0) {
    return EnvironmentPath(
      environmentId: documentId.substring(0, cut),
      path: documentId.substring(cut + _separator.length),
    );
  }
  final share = _wslShare.firstMatch(documentId);
  if (share != null) {
    final tail = (share.group(2) ?? '').replaceAll(r'\', '/');
    return EnvironmentPath(
      environmentId: 'wsl:${share.group(1)}',
      path: tail.isEmpty ? '/' : tail,
    );
  }
  return EnvironmentPath(
    environmentId: localHostEnvironmentId,
    path: documentId,
  );
}

/// [documentId] in its canonical spelling — what a fresh open of the same file
/// would be keyed by.
String canonicalDocumentId(String documentId) =>
    documentIdOf(documentPathOf(documentId));

/// Whether [documentId] names a file on this machine's own disk.
bool isLocalDocument(String documentId) =>
    documentPathOf(documentId).environmentId == localHostEnvironmentId;

/// The WSL distribution [environmentId] names, or null when it is not one.
/// WSL environment ids are `wsl:<distro>` by construction.
String? wslDistributionOf(String environmentId) =>
    environmentId.startsWith('wsl:') && environmentId.length > 4
    ? environmentId.substring(4)
    : null;

/// The file's own name. A local path may be spelled for Windows, whose context
/// reads `/` and `\` alike; everywhere else is POSIX, where `\` is a character.
String documentNameOf(String documentId) {
  final path = documentPathOf(documentId);
  return path.environmentId == localHostEnvironmentId
      ? p.windows.basename(path.path)
      : p.posix.basename(path.path);
}
