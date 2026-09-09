import '../environments/environment_kind.dart';
import '../environments/environment_path.dart';
import '../environments/execution_environment.dart';

/// Raised when a path cannot be translated between two environments.
class PathTranslationException implements Exception {
  PathTranslationException(this.message);
  final String message;
  @override
  String toString() => 'PathTranslationException: $message';
}

/// Translates paths **explicitly** between execution environments.
///
/// There is deliberately no implicit conversion anywhere else in the codebase
/// (constraint 8); callers that genuinely need to move a path from Windows to
/// WSL (or back) do it here, with both environments in hand.
///
/// Supported mappings:
/// * Windows drive path `C:\a\b` ⇄ WSL `/mnt/c/a/b`.
/// * WSL non-`/mnt` path `/home/x` → Windows UNC `\\wsl.localhost\<distro>\home\x`
///   and the reverse.
class PathTranslator {
  const PathTranslator();

  // Drive path with an optional separator (handles `C:`, `C:\`, `C:/x`, `C:\x\`).
  static final _windowsDrive = RegExp(r'^([A-Za-z]):[\\/]?(.*)$');
  static final _wslMount = RegExp(r'^/mnt/([a-zA-Z])(?:/(.*))?$');
  static final _wslAbsolute = RegExp(r'^/(.*)$');
  static final _unc = RegExp(r'^\\\\wsl(?:\.localhost|\$)\\([^\\]+)\\?(.*)$');

  static final _trailingWinSep = RegExp(r'[\\/]+$');
  static final _trailingPosixSep = RegExp(r'/+$');

  /// `C:\a\b` → `/mnt/c/a/b`. Accepts forward or back slashes, a bare drive
  /// (`C:` → `/mnt/c`), and trailing separators.
  String windowsDriveToWslMount(String windowsPath) {
    final m = _windowsDrive.firstMatch(windowsPath);
    if (m == null) {
      throw PathTranslationException(
        'Not an absolute Windows drive path: $windowsPath',
      );
    }
    final drive = m.group(1)!.toLowerCase();
    final rest = m
        .group(2)!
        .replaceAll(r'\', '/')
        .replaceAll(_trailingPosixSep, '');
    return rest.isEmpty ? '/mnt/$drive' : '/mnt/$drive/$rest';
  }

  /// `/mnt/c/a/b` → `C:\a\b`. Handles the drive root (`/mnt/c` → `C:\`) and
  /// trailing separators.
  String wslMountToWindowsDrive(String wslPath) {
    final m = _wslMount.firstMatch(wslPath);
    if (m == null) {
      throw PathTranslationException('Not a /mnt drive path: $wslPath');
    }
    final drive = m.group(1)!.toUpperCase();
    final rest = (m.group(2) ?? '')
        .replaceAll(_trailingPosixSep, '')
        .replaceAll('/', r'\');
    return rest.isEmpty ? '$drive:\\' : '$drive:\\$rest';
  }

  /// Translates [path] from environment [from] to environment [to].
  ///
  /// Returns [path] unchanged when both are the same environment. Throws
  /// [PathTranslationException] for mappings that are not defined (e.g. between
  /// two different WSL distributions).
  EnvironmentPath translate(
    EnvironmentPath path, {
    required ExecutionEnvironment from,
    required ExecutionEnvironment to,
  }) {
    if (from.id == to.id) return path;

    if (from.kind == EnvironmentKind.windowsNative &&
        to.kind == EnvironmentKind.wsl) {
      return EnvironmentPath(
        environmentId: to.id,
        path: _windowsToWsl(path.path, to),
      );
    }
    if (from.kind == EnvironmentKind.wsl &&
        to.kind == EnvironmentKind.windowsNative) {
      return EnvironmentPath(
        environmentId: to.id,
        path: _wslToWindows(path.path, from),
      );
    }
    throw PathTranslationException(
      'No path translation defined from ${from.id} to ${to.id}',
    );
  }

  String _windowsToWsl(String windowsPath, ExecutionEnvironment wslEnv) {
    if (_windowsDrive.hasMatch(windowsPath)) {
      return windowsDriveToWslMount(windowsPath);
    }
    final unc = _unc.firstMatch(windowsPath);
    if (unc != null) {
      final distro = unc.group(1)!;
      if (distro != wslEnv.wslDistribution) {
        throw PathTranslationException(
          'UNC path is for distribution "$distro", not "${wslEnv.wslDistribution}"',
        );
      }
      final rest = unc
          .group(2)!
          .replaceAll(_trailingWinSep, '')
          .replaceAll(r'\', '/');
      return '/$rest';
    }
    throw PathTranslationException(
      'Cannot translate Windows path to WSL: $windowsPath',
    );
  }

  String _wslToWindows(String wslPath, ExecutionEnvironment wslEnv) {
    if (_wslMount.hasMatch(wslPath)) {
      return wslMountToWindowsDrive(wslPath);
    }
    final abs = _wslAbsolute.firstMatch(wslPath);
    if (abs != null) {
      final distro = wslEnv.wslDistribution;
      if (distro == null) {
        throw PathTranslationException(
          'WSL environment ${wslEnv.id} has no distribution name',
        );
      }
      final rest = abs
          .group(1)!
          .replaceAll(_trailingPosixSep, '')
          .replaceAll('/', r'\');
      return rest.isEmpty
          ? r'\\wsl.localhost\'
                '$distro'
          : r'\\wsl.localhost\'
                '$distro\\$rest';
    }
    throw PathTranslationException(
      'Cannot translate WSL path to Windows: $wslPath',
    );
  }
}
