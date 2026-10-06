import 'package:agent_cli/descriptors.dart' show AcpLaunchSpec;
import 'package:agent_cli/discovery.dart'
    show AgentInstallation, isNpxExecutable, isStaleNpxRow;

/// The argv [installation] starts [spec]'s agent with over ACP — for a
/// session, its login and its version read alike: what discovery put in
/// front (`-y <package>` for an agent found only through npx) and the spec's
/// own mode arguments.
///
/// An npx row with nothing in front runs the package the spec declares; a
/// person's own agent whose command is npx names its package among the
/// spec's arguments and runs as given. A stale npx row ([isStaleNpxRow]) is
/// refused in words: it would otherwise run `npx <its mode arguments>`. The
/// server's start-up path check repairs such rows before anyone launches one.
List<String> acpArgumentsFor(
  AgentInstallation installation,
  AcpLaunchSpec spec, {
  required bool linux,
}) {
  final leading = installation.leadingArguments;
  final package = spec.npxPackage;
  final mode = spec.argumentsFor(linux: linux, version: installation.version);
  if (!isNpxExecutable(installation.executable.path)) {
    return [...leading, ...mode];
  }
  if (isStaleNpxRow(installation, spec)) {
    throw StateError(
      '${installation.agentId} is recorded as run through npx'
      '${leading.isEmpty ? '' : ' (${leading.join(' ')})'}, which is not how '
      'it is started now; rescan agents to find it again',
    );
  }
  if (leading.isEmpty && package != null) return ['-y', package, ...mode];
  return [...leading, ...mode];
}
