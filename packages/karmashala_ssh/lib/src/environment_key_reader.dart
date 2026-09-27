import 'package:agent_cli/process.dart';

import 'ssh_connection.dart';

/// Reads a private key from whichever **local** environment owns its path —
/// on the machine this runs on: the same text in a WSL distro and on Windows
/// are two different files. The server reads the keys of the hosts it dials;
/// the app reads the ones its own terminal panes dial with. A key never
/// crosses a wire.
class EnvironmentPrivateKeyReader {
  EnvironmentPrivateKeyReader({
    required this.environmentOf,
    this.translator = const PathTranslator(),
    this.readLocal = readLocalPrivateKey,
  });

  /// The recorded environment with an id, or null.
  final ExecutionEnvironment? Function(String id) environmentOf;
  final PathTranslator translator;

  /// How a path this machine can already open is read. Injected so tests
  /// exercise the translation without a filesystem.
  final PrivateKeyReader readLocal;

  Future<String> read(EnvironmentPath path) async {
    final owner = environmentOf(path.environmentId);
    // An unknown environment is read as written rather than guessed at;
    // `readLocalPrivateKey` still refuses anything remote.
    if (owner == null || owner.kind != EnvironmentKind.wsl) {
      return readLocal(path);
    }
    // The stored row only stands in for Windows when it really is Windows: on a
    // POSIX host it describes this machine, not the distribution's files.
    final stored = environmentOf(localHostEnvironmentId);
    final windows = stored?.kind == EnvironmentKind.windowsNative
        ? stored!
        : windowsHostEnvironment(owner.createdAt);
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

/// The environments a private key may be recorded in — every local one. A
/// remote one is excluded early, so a choice that cannot work is never offered.
List<ExecutionEnvironment> keyHostingEnvironments(
  List<ExecutionEnvironment> all,
) => [
  for (final environment in all)
    if (environment.kind != EnvironmentKind.ssh) environment,
];
