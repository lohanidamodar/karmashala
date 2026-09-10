/// Turning a path printed in a pane into a path on this machine.
///
/// Kept apart from `terminal_links.dart` because detection only has the line
/// and resolution needs the *pane*: `/home/me/src` is one place inside a WSL
/// pane and nowhere at all inside a PowerShell one, the same rule
/// `EnvironmentPath` enforces elsewhere. Pure — what is actually *at* the
/// resolved path is asked once per candidate by the pane.
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
/// A drive or UNC path is already the host's spelling and only has its
/// separators normalised. A POSIX-absolute path is on this machine only if the
/// pane can say where — a WSL pane maps it through [PathTranslator], and a pane
/// whose own working directory is POSIX is on a POSIX host — so a POSIX path
/// printed in a PowerShell pane resolves to nothing. `~` resolves to nothing
/// too: the home it means belongs to whichever user the program ran as.
/// Anything else is relative, joined onto [workingDirectory] in that
/// directory's own flavour and then translated by the same rule.
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
  // A POSIX working directory is the pane's own spelling, not the host's, so a
  // join onto it needs exactly the translation an absolute POSIX path already
  // gets: without it the join went to a Windows `stat`, which found nothing, so
  // absolute paths were clickable and relative ones silently were not.
  //
  // A Windows-shaped relative path needs nothing special here, though it looks
  // as though it should: the translation rewrites forward slashes and leaves
  // backslashes alone, so both readings arrive at the same host path. Measured
  // — this was filed as a bug and the probe showed them resolving identically.
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
