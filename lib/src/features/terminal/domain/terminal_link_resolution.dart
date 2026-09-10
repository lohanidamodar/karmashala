/// Turning a path printed in a pane into a path on this machine — resolution
/// needs the *pane*, because `/home/me/src` means nothing in a PowerShell one.
library;

import 'package:path/path.dart' as p;

import 'package:agent_cli/process.dart';
import 'terminal_links.dart';
import 'terminal_profile.dart';

final RegExp _windowsAbsolute = RegExp(r'^[A-Za-z]:[\\/]');

/// The translator only reads an environment's kind and distribution, so the
/// timestamp on the two it is handed is never looked at.
final DateTime _unused = DateTime.utc(1970);

/// [target] spelled as a path on the host, or null. A POSIX path resolves only
/// if the pane says where it is; `~` never does, the home being the program's.
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
  // A POSIX working directory is the pane's spelling, so a join onto it needs
  // the same translation: without it, relative paths silently did not resolve.
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
