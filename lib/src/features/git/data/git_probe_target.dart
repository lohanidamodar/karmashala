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
/// Measured on the owner's machine, one repository and one `git` command:
/// 101 ms warm from Windows, **3699 ms warm and 17786 ms cold** from WSL over
/// `/mnt/c`, and 9 ms for a WSL-native checkout from WSL. Git stats thousands
/// of files and every one of them crosses DrvFs, so the 37x is the translation
/// layer rather than git. A checkout on the Windows disk is therefore probed by
/// Windows git even when its sessions run in WSL — which is the shape the owner
/// isolated: *"one project was in windows but accessed via wsl and all sessions
/// wsl, this is the one that lagged."*
///
/// **Matched:** `/mnt/<drive>/…` in an [EnvironmentKind.wsl] row. That is WSL's
/// default automount and the only path shape that names a Windows file without
/// asking the distribution anything — [PathTranslator.wslMountToWindowsDrive]
/// both recognises and converts it.
///
/// **Not matched, deliberately:** a distribution whose `[automount] root` is
/// somewhere else (`/windir/c/…`), because reading `wsl.conf` costs the spawn
/// this exists to avoid; every non-`/mnt` path, which is a real ext4 file and
/// already 9 ms where it is; and `\\wsl.localhost\…`, the reverse direction —
/// §18 measures that share as working but slow, so moving a probe onto it would
/// be moving it the wrong way.
///
/// Every uncertainty answers [environment] unchanged, which is what the app did
/// before this existed: no local host row, a host row that is not Windows, an
/// unrecognised mount, a WSL row with no distribution, SSH. [windowsHost] is a
/// callback so a checkout that is not in WSL never spends the lookup.
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
