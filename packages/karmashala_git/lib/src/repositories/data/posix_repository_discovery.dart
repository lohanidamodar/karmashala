import 'dart:async';
import 'dart:convert';

import 'package:agent_cli/process.dart';
import 'package:path/path.dart' as p;

import '../domain/discovered_repository.dart';
import 'checkout_presence_probe.dart';
import 'repository_discovery.dart';

/// Finds Git repositories under a POSIX folder by running `find` through a
/// [CommandRunner] — a WSL distribution or an SSH box, whose files this
/// process cannot walk itself. The same skip list and depth as
/// [LocalRepositoryDiscoveryService].
class PosixRepositoryDiscovery {
  const PosixRepositoryDiscovery(this.runner, {required this.environmentName});

  final CommandRunner runner;

  /// For a refusal: which machine could not be scanned.
  final String environmentName;

  Future<List<DiscoveredRepository>> discover(
    EnvironmentPath root, {
    int maxDepth = 5,
  }) async {
    final findDepth = maxDepth < 0 ? 1 : maxDepth + 1;
    final skipped = kSkippedDiscoveryDirectories
        .map((name) => '-name ${posixQuote(name)}')
        .join(' -o ');
    final prune = r'\( -type d \( ' + skipped + r' \) -prune \) -o';
    final script =
        '''
ROOT=${posixQuote(root.path)}
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
        detail.isEmpty
            ? 'Could not scan ${root.path} in $environmentName.'
            : detail,
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

  /// Whether [directory] is there, asked of the machine itself: `absent` only
  /// when `test -d` answered no; a runner that failed is `unknown`.
  Future<CheckoutPresence> presenceOf(EnvironmentPath directory) async {
    try {
      final result = await runner
          .run(
            CommandRequest(
              executable: 'sh',
              arguments: [
                '-c',
                'if [ -d ${posixQuote(directory.path)} ]; then echo yes; '
                    'else echo no; fi',
              ],
            ),
          )
          .timeout(presenceProbeDeadline * 5);
      if (!result.ok) return CheckoutPresence.unknown;
      return switch (result.stdout.trim()) {
        'yes' => CheckoutPresence.present,
        'no' => CheckoutPresence.absent,
        _ => CheckoutPresence.unknown,
      };
    } on Object {
      return CheckoutPresence.unknown;
    }
  }
}
