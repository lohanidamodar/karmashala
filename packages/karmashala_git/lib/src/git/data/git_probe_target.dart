import 'package:agent_cli/process.dart';

/// Which environment answers a read-only git question about a checkout, and
/// how the path is spelled for it.
class GitProbeTarget {
  const GitProbeTarget({required this.environment, required this.path});

  final ExecutionEnvironment environment;
  final EnvironmentPath path;
}

/// **Where a read-only git question is cheapest to ask: where the files are.**
///
/// Measured on the owner's machine, one `git` command in one repository: 101 ms
/// warm from Windows against **3699 ms warm and 17786 ms cold** from WSL over
/// `/mnt/c`, and 9 ms for a WSL-native checkout. Git stats thousands of files and
/// every one of them crosses DrvFs.
///
/// Only `/mnt/<drive>/…` in an [EnvironmentKind.wsl] row is moved: reading a
/// relocated `[automount] root` would cost the spawn this avoids, and
/// `\\wsl.localhost\…` is the slow direction. Everything else is unchanged.
GitProbeTarget gitProbeTargetFor(
  EnvironmentPath checkout,
  ExecutionEnvironment environment, {
  required ExecutionEnvironment? Function() windowsHost,
}) {
  final asFiled = GitProbeTarget(environment: environment, path: checkout);
  if (environment.kind != EnvironmentKind.wsl) return asFiled;

  // Selected by the host row's kind, never by `Platform` (§18). WSL rows are
  // only written on Windows, so off Windows this is unreachable in practice —
  // and a database carried to a Mac must still not send `C:\…` to its shell.
  final host = windowsHost();
  if (host == null || host.kind != EnvironmentKind.windowsNative) {
    return asFiled;
  }

  try {
    return GitProbeTarget(
      environment: host,
      path: EnvironmentPath(
        environmentId: host.id,
        path: const PathTranslator().wslMountToWindowsDrive(checkout.path),
      ),
    );
  } on PathTranslationException {
    return asFiled;
  }
}
