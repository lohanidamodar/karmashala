/// Turning a path printed in a pane into a path on this machine.
///
/// Kept apart from `terminal_links.dart` because detection only has the line,
/// and resolution needs the *pane*: which directory it opened in, and which
/// shell it runs. A path is only meaningful with its environment attached —
/// `/home/me/src` is one place inside a WSL pane and nowhere at all inside a
/// PowerShell one — which is the same rule `EnvironmentPath` exists to enforce
/// everywhere else in the app.
///
/// Pure: no filesystem, no database, no providers. What is actually *at* the
/// resolved path is a separate question, asked once per candidate by the pane.
library;

import 'package:path/path.dart' as p;

import '../../../core/process/path_translator.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/execution_environment.dart';
import '../../environments/domain/local_environment.dart';
import 'terminal_links.dart';
import 'terminal_profile.dart';

final RegExp _windowsAbsolute = RegExp(r'^[A-Za-z]:[\\/]');

/// The translator only reads an environment's kind and distribution, so the
/// timestamp on the two it is handed is never looked at.
final DateTime _unused = DateTime.utc(1970);

/// [target] spelled as a path on the host, or null when there is none.
///
/// The rules, in order:
///
/// * a drive path (`C:\src`, `C:/src`) or a UNC path (`\\wsl.localhost\…`) is
///   already the host's spelling — only its separators are normalised;
/// * a POSIX-absolute path is somewhere on this machine only if the pane can
///   say where: a WSL pane maps it through [PathTranslator] to `/mnt/<drive>`'s
///   Windows form or to `\\wsl.localhost\<distro>\…`, and a pane whose own
///   working directory is POSIX is one on a POSIX host, so the path stands as
///   it is. A POSIX path printed in a PowerShell pane resolves to nothing,
///   because nothing here knows which machine it was talking about;
/// * `~` resolves to nothing: the home directory it means belongs to whichever
///   user the program was running as, and the pane never learns it;
/// * anything else is relative, and is joined onto [workingDirectory] in that
///   directory's own flavour — the one thing a relative path in a pane can mean.
String? hostPathForTerminalTarget(
  PathTarget target, {
  required String? workingDirectory,
  required String profileId,
}) {
  final raw = target.path;
  if (raw.isEmpty) return null;
  if (_windowsAbsolute.hasMatch(raw) || raw.startsWith(r'\\')) {
    return p.windows.normalize(raw.replaceAll('/', r'\'));
  }
  if (raw.startsWith('~')) return null;
  if (raw.startsWith('/')) {
    return _hostPathForPosix(
      raw,
      profileId: profileId,
      workingDirectory: workingDirectory,
    );
  }

  final base = workingDirectory;
  if (base == null || base.isEmpty) return null;
  final context = _isWindowsPath(base) ? p.windows : p.posix;
  final relative = context == p.windows ? raw.replaceAll('/', r'\') : raw;
  return context.normalize(context.join(base, relative));
}

String? _hostPathForPosix(
  String raw, {
  required String profileId,
  required String? workingDirectory,
}) {
  final distro = terminalProfileFromId(profileId)?.wslDistribution;
  if (distro != null && distro.isNotEmpty) {
    final wsl = ExecutionEnvironment(
      id: TerminalProfile.wslId(distro),
      kind: EnvironmentKind.wsl,
      name: distro,
      wslDistribution: distro,
      createdAt: _unused,
    );
    try {
      return const PathTranslator()
          .translate(
            EnvironmentPath(
              environmentId: wsl.id,
              path: p.posix.normalize(raw),
            ),
            from: wsl,
            to: localWindowsEnvironment(_unused),
          )
          .path;
    } on PathTranslationException {
      return null;
    }
  }
  // Not a WSL pane. The pane's own directory is the honest evidence for which
  // kind of host this is; a POSIX one needs no translation at all.
  final base = workingDirectory;
  if (base != null && base.startsWith('/')) return p.posix.normalize(raw);
  return null;
}

bool _isWindowsPath(String path) =>
    _windowsAbsolute.hasMatch(path) || path.startsWith(r'\\');
