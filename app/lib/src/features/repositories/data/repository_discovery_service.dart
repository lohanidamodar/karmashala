import 'dart:convert';

import 'package:path/path.dart' as p;

import 'package:agent_cli/process.dart';
import '../../environments/application/environment_resolver.dart';
import '../../environments/data/execution_environment_dao.dart';
import 'package:karmashala_git/repositories.dart';

/// A [RepositoryDiscoveryService] that uses the local filesystem for host
/// paths and a command runner for POSIX paths in WSL and SSH environments.
class EnvironmentAwareRepositoryDiscoveryService
    implements RepositoryDiscoveryService {
  const EnvironmentAwareRepositoryDiscoveryService({
    required this.localDiscovery,
    required this.runnerFactory,
    required this.environments,
  });

  final RepositoryDiscoveryService localDiscovery;
  final CommandRunnerFactory runnerFactory;
  final ExecutionEnvironmentDao environments;

  @override
  Future<List<DiscoveredRepository>> discover(
    EnvironmentPath root, {
    int maxDepth = 5,
  }) async {
    final env = ExecutionEnvironmentResolver(
      environments: environments,
      runners: runnerFactory,
    ).resolveFor(root).environment;
    if (env != null &&
        (env.kind == EnvironmentKind.ssh || env.kind == EnvironmentKind.wsl)) {
      return _discoverPosix(root, env, maxDepth: maxDepth);
    }
    return localDiscovery.discover(root, maxDepth: maxDepth);
  }

  Future<List<DiscoveredRepository>> _discoverPosix(
    EnvironmentPath root,
    ExecutionEnvironment env, {
    int maxDepth = 5,
  }) async {
    final runner = runnerFactory.forEnvironment(env);
    final findDepth = maxDepth < 0 ? 1 : maxDepth + 1;
    final escaped = "'${root.path.replaceAll("'", r"'\''")}'";
    final skipped = kSkippedDiscoveryDirectories
        .map((name) => '-name ${_posixQuote(name)}')
        .join(' -o ');
    final prune = r'\( -type d \( ' + skipped + r' \) -prune \) -o';
    final script =
        '''
ROOT=$escaped
if [ ! -d "\$ROOT" ]; then
  echo "Repository root does not exist: \$ROOT" >&2
  exit 2
fi
find "\$ROOT" -maxdepth $findDepth $prune -name .git -print
''';
    final result = await runner.run(
      CommandRequest(executable: 'sh', arguments: ['-c', script]),
    );
    if (!result.ok) {
      final detail = result.stderr.trim();
      throw RepositoryDiscoveryException(
        detail.isEmpty ? 'Could not scan ${root.path} in ${env.name}.' : detail,
      );
    }

    final seen = <String>{};
    final found = <DiscoveredRepository>[];
    for (final line in const LineSplitter().convert(result.stdout)) {
      var trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith("'") && trimmed.endsWith("'")) {
        trimmed = trimmed.substring(1, trimmed.length - 1);
      }
      if (trimmed.endsWith('/.git')) {
        trimmed = trimmed.substring(0, trimmed.length - 5);
      }
      final parts = trimmed.split('/');
      if (parts.any(kSkippedDiscoveryDirectories.contains)) continue;

      if (seen.add(trimmed)) {
        found.add(
          DiscoveredRepository(
            name: p.posix.basename(trimmed),
            path: EnvironmentPath(
              environmentId: root.environmentId,
              path: trimmed,
            ),
          ),
        );
      }
    }
    found.sort((a, b) => a.path.path.compareTo(b.path.path));
    return found;
  }

  static String _posixQuote(String value) =>
      "'${value.replaceAll("'", r"'\''")}'";
}
