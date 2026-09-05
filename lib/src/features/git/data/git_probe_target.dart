import '../../../core/process/path_translator.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/execution_environment.dart';

/// Which environment answers a read-only git question about a checkout, and
/// how the path is spelled for it.
class GitProbeTarget {
  const GitProbeTarget({required this.environment, required this.path});

  final ExecutionEnvironment environment;
  final EnvironmentPath path;
}

/// **Where a read-only git question is cheapest to ask: where the files are.**
///
/// One repository, one `git` command, measured on the owner's machine: 101 ms
/// warm from Windows, **3699 ms warm and 17786 ms cold** from WSL over
/// `/mnt/c`, 9 ms for a WSL-native checkout from WSL. Git stats thousands of
/// files and every one crosses DrvFs, so the 37x is the translation layer.
///
/// **Matched:** `/mnt/<drive>/…` in an [EnvironmentKind.wsl] row — WSL's
/// default automount, and the only shape that names a Windows file without
/// asking the distribution anything. [PathTranslator.wslMountToWindowsDrive]
/// both recognises and converts it.
///
/// **Not matched:** a `[automount] root` set elsewhere (`/windir/c/…`), since
/// reading `wsl.conf` costs the spawn this avoids; any non-`/mnt` path, already
/// 9 ms where it is; and `\\wsl.localhost\…`, the reverse direction, which §18
/// measures as slow — moving a probe onto it goes the wrong way.
///
/// Every other case answers [environment] unchanged, as the app did before.
/// [windowsHost] is a callback so a non-WSL checkout never spends the lookup.
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
