import 'package:agent_cli/descriptors.dart' show AcpLaunchSpec;
import 'package:agent_cli/discovery.dart'
    show AgentInstallation, isNpxExecutable;

/// The argv [installation] starts [spec]'s agent with over ACP — for a
/// session, its login and its version read alike: what discovery put in
/// front (`-y <package>` for an agent found only through npx) and the spec's
/// own mode arguments.
///
/// An npx row with nothing in front runs the package the spec declares; a
/// person's own agent whose command is npx names its package among the
/// spec's arguments and runs as given. An npx row is refused in words when
/// the spec is spoken to through a bridge, declares no package of its own,
/// or another package than the row names: a row recorded before the agent
/// left npx would otherwise run `npx <its mode arguments>`.
List<String> acpArgumentsFor(
  AgentInstallation installation,
  AcpLaunchSpec spec, {
  required bool linux,
}) {
  final leading = installation.leadingArguments;
  final package = spec.npxPackage;
  final mode = spec.argumentsFor(linux: linux);
  if (!isNpxExecutable(installation.executable.path)) {
    return [...leading, ...mode];
  }
  final named = _packageIn(leading);
  final stale =
      spec.nativeBridge != null ||
      (leading.isNotEmpty && (package == null || named != package));
  if (stale) {
    throw StateError(
      '${installation.agentId} is recorded as run through npx'
      '${leading.isEmpty ? '' : ' (${leading.join(' ')})'}, which is not how '
      'it is started now; rescan agents to find it again',
    );
  }
  if (leading.isEmpty && package != null) return ['-y', package, ...mode];
  return [...leading, ...mode];
}

/// The package an npx row's leading arguments run, without its version:
/// `-y @scope/name@1.2` names `@scope/name`.
String? _packageIn(List<String> leading) {
  final words = [
    for (final word in leading)
      if (!word.startsWith('-')) word,
  ];
  if (words.isEmpty) return null;
  final spelled = words.first;
  final at = spelled.lastIndexOf('@');
  return at > 0 ? spelled.substring(0, at) : spelled;
}
