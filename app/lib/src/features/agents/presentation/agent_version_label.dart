import 'package:agent_cli/discovery.dart';

/// What a surface says of an agent run from its package through npx before
/// the agent itself has answered: npx is not the agent, so its own version is
/// never shown.
const String npxFallbackLine = 'via npx · downloaded on first start';

/// What a surface says when no version was read and nothing explains why.
const String versionNotReadLine = 'version not read';

/// Whether [install] runs through a package runner rather than its own
/// binary — `AgentInstallation.leadingArguments` is how discovery records it.
bool runsThroughNpx(AgentInstallation install) =>
    install.leadingArguments.isNotEmpty;

/// The newest of [installs]' versions, or null when fewer than two machines
/// have one — a flag needs something to be behind.
String? newestAgentVersion(List<AgentInstallation> installs) {
  final versions = [for (final install in installs) ?install.version];
  if (versions.length < 2) return null;
  return versions.reduce((a, b) => compareAgentVersions(a, b) >= 0 ? a : b);
}

/// The version to show for [installs] as one line: the newest reading with
/// its age; for an agent found only through npx and not yet read,
/// [npxFallbackLine]; otherwise [versionNotReadLine].
String describeAgentVersions(
  List<AgentInstallation> installs, {
  required DateTime now,
}) {
  final read = [
    for (final install in installs)
      if (install.version != null) install,
  ];
  if (read.isEmpty) {
    return installs.any(runsThroughNpx) ? npxFallbackLine : versionNotReadLine;
  }
  final newest = newestAgentVersion(installs);
  final shown = read.firstWhere(
    (install) => install.version == newest,
    orElse: () => read.first,
  );
  return describeVersionReading(shown, now: now) ?? versionNotReadLine;
}

/// One installation's version for a card: its reading, [npxFallbackLine]
/// when it runs through npx unread, or null when there is nothing to say.
String? describeInstallVersion(AgentInstallation install) =>
    install.version ?? (runsThroughNpx(install) ? npxFallbackLine : null);
