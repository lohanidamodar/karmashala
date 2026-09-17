import 'dart:convert';

import 'package:karmashala_core/logging.dart';

import 'host_deploy_target.dart';

/// What Karmashala hangs off a remote home. A *fragment*, never a path: `mkdir`
/// expands `$HOME`, SFTP does not, so a literal `$HOME/...` names nothing.
const String kRemoteHomeSubdirectory = '.karmashala';

/// The remote home as an absolute path, asked of the machine's shell. Null is
/// *unknown*, never a guess at `/home/<user>`; the last non-empty line wins.
Future<String?> resolveRemoteHome(
  HostDeployTarget target, {
  AppLogger? logger,
}) async {
  final RemoteRun result;
  try {
    result = await target.run('echo "\$HOME"');
  } on Object catch (e) {
    logger?.debug('${target.address} could not be asked for \$HOME: $e');
    return null;
  }
  final lines = const LineSplitter()
      .convert(result.stdout)
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty);
  if (lines.isEmpty) return null;
  final home = lines.last;
  // An answer that is not an absolute path is not an answer: `$HOME` unset
  // echoes an empty line, and a shell that printed a complaint is not a home.
  if (!home.startsWith('/')) return null;
  return home.length > 1 && home.endsWith('/')
      ? home.substring(0, home.length - 1)
      : home;
}

/// For shell commands built here. The remote home is the machine's word, not
/// ours, so it is quoted rather than trusted to be one word.
String quoteForRemoteShell(String value) =>
    "'${value.replaceAll("'", r"'\''")}'";
