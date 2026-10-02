// The environment fixtures and the porcelain v2 builder the moved suites
// need, copied from the app's test/support/fixtures.dart (a package cannot
// import another package's test tree).
import 'package:agent_cli/process.dart';

/// Fixed timestamp used across tests for determinism.
final testTime = DateTime.utc(2026, 1, 2, 3, 4, 5);

ExecutionEnvironment windowsEnv({String id = 'windows'}) =>
    ExecutionEnvironment(
      id: id,
      kind: EnvironmentKind.windowsNative,
      name: 'Windows',
      createdAt: testTime,
    );

/// The local macOS/Linux host, for the cases that are about a POSIX desktop
/// rather than about Windows.
ExecutionEnvironment posixEnv({String id = 'windows', String name = 'macOS'}) =>
    ExecutionEnvironment(
      id: id,
      kind: EnvironmentKind.localPosix,
      name: name,
      createdAt: testTime,
    );

ExecutionEnvironment wslEnv({
  String id = 'wsl:Ubuntu',
  String distro = 'Ubuntu',
}) => ExecutionEnvironment(
  id: id,
  kind: EnvironmentKind.wsl,
  name: distro,
  wslDistribution: distro,
  createdAt: testTime,
);

ExecutionEnvironment sshEnvFixture({
  String id = 'ssh:h1',
  String hostId = 'h1',
  String name = 'build-box',
}) => ExecutionEnvironment(
  id: id,
  kind: EnvironmentKind.ssh,
  name: name,
  sshHostId: hostId,
  createdAt: testTime,
);

/// One `git status --porcelain=v2 --branch` reply, which is what the app asks
/// for and therefore the only status text a fixture should pin.
///
/// [ahead] and [behind] default to zero because that is what an upstream at
/// parity means, and v2 says so out loud (`# branch.ab +0 -0`) where v1 said it
/// by printing nothing. Pass null to leave the header out, which is what git does
/// when it **cannot** compute the distance.
String porcelainV2({
  String? branch = 'main',
  String? upstream,
  int? ahead = 0,
  int? behind = 0,
  List<String> modified = const [],
  List<String> staged = const [],
  List<String> untracked = const [],
  List<String> unmerged = const [],
  Map<String, String> renamed = const {},
  bool initial = false,
}) {
  const sha = '0000000000000000000000000000000000000000';
  const modes = '100644 100644 100644';
  return [
    '# branch.oid ${initial ? '(initial)' : 'f1e2d3c4b5a69788f1e2d3c4b5a69788f1e2d3c4'}',
    '# branch.head ${branch ?? '(detached)'}',
    if (upstream != null) '# branch.upstream $upstream',
    if (upstream != null && ahead != null && behind != null)
      '# branch.ab +$ahead -$behind',
    for (final path in staged) '1 M. N... $modes $sha $sha $path',
    for (final path in modified) '1 .M N... $modes $sha $sha $path',
    // `<path>\t<origPath>`, tab-separated, which is the shape v1 never writes.
    for (final entry in renamed.entries)
      '2 R. N... $modes $sha $sha R100 ${entry.key}\t${entry.value}',
    // An unmerged path is its own record type in v2, where v1 wrote `UU`.
    for (final path in unmerged)
      'u UU N... 100644 100644 100644 100644 $sha $sha $sha $path',
    for (final path in untracked) '? $path',
    '',
  ].join('\n');
}
