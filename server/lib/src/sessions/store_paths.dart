import 'package:agent_cli/process.dart';

/// The canonical key of [path] in [environment], so a WSL row and the store
/// record it wrote — `/mnt/c/src/app` and `C:\src\app` — compare as one
/// folder. The app's detected-projects view keys folders the same way
/// (`canonicalProjectPath`); this is the server's copy of that rule, for the
/// session sync alone.
String canonicalStoreKey(
  EnvironmentPath path,
  ExecutionEnvironment? environment, [
  PathTranslator translator = const PathTranslator(),
]) {
  final trimmed = path.path.replaceAll(RegExp(r'[\\/]+$'), '');
  if (environment != null &&
      environment.kind == EnvironmentKind.windowsNative) {
    return trimmed.replaceAll('/', r'\').toLowerCase();
  }
  if (environment != null &&
      environment.kind == EnvironmentKind.wsl &&
      RegExp(r'^/mnt/[a-zA-Z](/|$)').hasMatch(trimmed)) {
    try {
      return translator.wslMountToWindowsDrive(trimmed).toLowerCase();
    } on PathTranslationException {
      // Not a drive mount after all: keyed in its own environment.
    }
  }
  return '${path.environmentId}:${trimmed.toLowerCase()}';
}

/// [path] with one separator, no trailing one, in lower case — how a pane's
/// directory, which names no environment, is compared with a hook's.
String flattenedPath(String path) =>
    path.replaceAll(r'\', '/').replaceAll(RegExp(r'/+$'), '').toLowerCase();
