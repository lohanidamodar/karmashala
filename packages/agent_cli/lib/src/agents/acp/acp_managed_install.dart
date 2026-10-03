import '../../environments/environment_kind.dart';
import '../../process/command_runner.dart';
import '../data/agent_discovery_service.dart' show expandWindowsPath;
import '../domain/agent_version_reading.dart' show compareAgentVersions;

/// Where Karmashala installs an ACP agent the registry ships as a prebuilt
/// archive, under the environment's home:
/// `~/karmashala/acp/<registry id>/<version>/`. One folder per version, so
/// an upgrade sits beside the build it replaces and discovery takes the
/// newest.
const String kAcpManagedFolder = 'karmashala/acp';

/// The folder's segments after the home, spelled for [kind].
String acpManagedDirectory(
  EnvironmentKind kind,
  String registryId,
  String version,
) {
  final separator = usesWindowsPaths(kind) ? r'\' : '/';
  return [...kAcpManagedFolder.split('/'), registryId, version].join(separator);
}

/// The command that lists every one of [names] installed in the managed
/// folder of [registryId], one absolute path per line — `ls` over a glob
/// through the login shell on POSIX, `where /r` on Windows (whose home is
/// read from [hostEnvironment]; null when it is not set). Nothing here
/// expands a variable on the way, so a WSL login shell parsing the line
/// first changes nothing.
CommandRequest? acpManagedLocateRequest(
  EnvironmentKind kind,
  String registryId,
  List<String> names, {
  Map<String, String> hostEnvironment = const {},
}) {
  if (names.isEmpty) return null;
  if (isPosixShell(kind)) {
    final globs = [
      for (final name in names) '~/$kAcpManagedFolder/$registryId/*/$name',
    ].join(' ');
    return CommandRequest(
      executable: 'bash',
      arguments: ['-lc', 'ls -1 $globs 2>/dev/null'],
      timeout: kProbeTimeout,
    );
  }
  final root = expandWindowsPath(
    '%USERPROFILE%\\${kAcpManagedFolder.replaceAll('/', r'\')}\\$registryId',
    hostEnvironment,
  );
  if (root == null) return null;
  return CommandRequest(
    executable: 'where',
    arguments: ['/r', root, ...names],
    timeout: kProbeTimeout,
  );
}

/// The newest install among the paths a managed lookup printed — the
/// version is the folder the executable sits in — or null for none.
({String path, String version})? newestAcpManagedInstall(String stdout) {
  ({String path, String version})? newest;
  for (final line in stdout.split(RegExp(r'[\r\n]+'))) {
    final path = line.trim();
    if (path.isEmpty) continue;
    final segments = path.split(RegExp(r'[\\/]'));
    if (segments.length < 2) continue;
    final version = segments[segments.length - 2];
    if (newest == null || compareAgentVersions(version, newest.version) > 0) {
      newest = (path: path, version: version);
    }
  }
  return newest;
}
