import '../../../core/process/path_translator.dart';
import '../../environments/data/execution_environment_dao.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/execution_environment.dart';
import '../../environments/domain/local_environment.dart';
import 'ssh_connection.dart';

/// Reads a private key from whichever **local** environment owns its path.
///
/// A key path is stored paired with its environment (principle 2), and that
/// pairing is not decoration: `/home/me/.ssh/id_ed25519` recorded in a WSL
/// distribution and the same text recorded on the Windows host are two
/// different files, and the desktop process — which reads with the Windows
/// API — can only open one of them directly. So a WSL-owned key is translated
/// to its `\\wsl.localhost\<distro>\…` form before being read, and a remote key
/// is refused outright: fetching a key over the connection it is meant to
/// authenticate is not a thing that can work.
class EnvironmentPrivateKeyReader {
  EnvironmentPrivateKeyReader({
    required this.environments,
    this.translator = const PathTranslator(),
    this.readLocal = readLocalPrivateKey,
  });

  final ExecutionEnvironmentDao environments;
  final PathTranslator translator;

  /// How a path that the Windows host can already open is read. Injected so
  /// tests exercise the translation without a filesystem.
  final PrivateKeyReader readLocal;

  Future<String> read(EnvironmentPath path) async {
    final owner = environments.getById(path.environmentId);
    // An unknown environment is read as written rather than guessed at;
    // `readLocalPrivateKey` still refuses anything remote.
    if (owner == null || owner.kind != EnvironmentKind.wsl) {
      return readLocal(path);
    }
    final windows =
        environments.getById(localWindowsEnvironmentId) ??
        localWindowsEnvironment(owner.createdAt);
    final EnvironmentPath onHost;
    try {
      onHost = translator.translate(path, from: owner, to: windows);
    } on PathTranslationException catch (e) {
      throw SshConnectionException(
        'The private key ${path.path} in ${owner.name} cannot be reached from '
        'the Windows host: ${e.message}',
        cause: e,
      );
    }
    return readLocal(onHost);
  }
}

/// The environments a private key may be recorded in — every local one.
///
/// A remote environment is excluded on purpose, and not as a UI nicety: it is
/// the same rule `readLocalPrivateKey` enforces, applied early enough that the
/// user is never offered a choice that cannot work.
List<ExecutionEnvironment> keyHostingEnvironments(
  List<ExecutionEnvironment> all,
) => [
  for (final environment in all)
    if (environment.kind != EnvironmentKind.ssh) environment,
];
