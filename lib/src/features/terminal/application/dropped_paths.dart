import 'package:agent_cli/process.dart';

/// Where a pane's process runs, as far as a file on this machine is concerned.
enum PaneReach {
  /// This machine, in its own path spelling.
  local,

  /// A WSL distribution on this Windows machine: drive paths become `/mnt/…`.
  wsl,

  /// Another machine: nothing dropped here exists there.
  ssh,
}

/// What dropping [paths] into a pane types — each path in the spelling and
/// quoting the pane's side reads, space-separated, with a trailing space as a
/// native terminal leaves — or null when the pane cannot reach them.
String? droppedPathsText(
  List<String> paths, {
  required PaneReach reach,
  required bool windowsHost,
}) {
  if (paths.isEmpty || reach == PaneReach.ssh) return null;
  const translator = PathTranslator();
  final spelled = <String>[];
  for (final path in paths) {
    if (reach == PaneReach.wsl) {
      try {
        spelled.add(_posixQuoted(translator.windowsDriveToWslMount(path)));
      } on PathTranslationException {
        // A UNC or other path WSL has no mount for.
        return null;
      }
    } else {
      spelled.add(windowsHost ? _windowsQuoted(path) : _posixQuoted(path));
    }
  }
  return '${spelled.join(' ')} ';
}

final RegExp _posixPlain = RegExp(r'^[A-Za-z0-9_./@%+=:,-]+$');

String _posixQuoted(String path) =>
    _posixPlain.hasMatch(path) ? path : "'${path.replaceAll("'", r"'\''")}'";

/// Double quotes, as Windows Terminal drops a path: `"` cannot appear in a
/// Windows file name, so nothing inside needs escaping.
String _windowsQuoted(String path) =>
    RegExp(r'[\s&()^;,=!]').hasMatch(path) ? '"$path"' : path;
