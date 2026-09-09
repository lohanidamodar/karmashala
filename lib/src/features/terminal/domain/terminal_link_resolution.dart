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

import 'package:agent_cli/process.dart';
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
///   directory's own flavour — the one thing a relative path in a pane can
///   mean — and the join is then translated by the same rule as an absolute
///   path, because a POSIX working directory is the pane's spelling and not
///   the host's.
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
  if (_isWindowsPath(base)) {
    return p.windows.normalize(p.windows.join(base, raw.replaceAll('/', r'\')));
  }
  // A POSIX working directory is the pane's own spelling, not the host's — a
  // WSL pane opened at `/mnt/c/src/app` or `/home/me/proj` says so in its own
  // namespace. Joining onto it produces a path in that namespace, which then
  // needs exactly the translation an absolute POSIX path already got: without
  // it the join was handed to a Windows `stat`, which found nothing, so
  // absolute paths were clickable and relative ones silently were not.
  //
  // A Windows-shaped relative path — `windows\installer\out\x.exe`, which is
  // what a Windows tool prints when `binfmt_misc` runs it from a WSL pane —
  // needs nothing special here, though it looks as though it should. The join
  // does leave those backslashes in place as ordinary characters, but the
  // translation below rewrites `/` to `\` and leaves `\` alone, so the two
  // readings arrive at the same host path. Measured, not assumed: this was
  // filed as a bug and the probe showed both spellings resolving identically.
  return _hostPathForPosix(
    p.posix.join(base, raw),
    profileId: profileId,
    workingDirectory: base,
  );
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
            to: windowsHostEnvironment(_unused),
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
