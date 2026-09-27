/// How an open file is named: the environment it lives in and its path in that
/// environment's own spelling — an [EnvironmentPath] — written as one string so
/// it can key a buffer and ride inside a pane id.
library;

import 'package:agent_cli/process.dart';
import 'package:path/path.dart' as p;

/// Separates the environment from the path. The same separator pane ids use,
/// because no path can contain it.
const String _separator = '␟';

/// The id of the document at [path]. The server's own machine's files keep
/// their bare path, and anything elsewhere is `<environment>␟<path>`.
String documentIdOf(EnvironmentPath path) =>
    path.environmentId == localHostEnvironmentId
    ? path.path
    : '${path.environmentId}$_separator${path.path}';

/// The file [documentId] names.
EnvironmentPath documentPathOf(String documentId) {
  final cut = documentId.indexOf(_separator);
  if (cut > 0) {
    return EnvironmentPath(
      environmentId: documentId.substring(0, cut),
      path: documentId.substring(cut + _separator.length),
    );
  }
  return EnvironmentPath(
    environmentId: localHostEnvironmentId,
    path: documentId,
  );
}

/// The file's own name. A local path may be spelled for Windows, whose context
/// reads `/` and `\` alike; everywhere else is POSIX, where `\` is a character.
String documentNameOf(String documentId) {
  final path = documentPathOf(documentId);
  return path.environmentId == localHostEnvironmentId
      ? p.windows.basename(path.path)
      : p.posix.basename(path.path);
}
