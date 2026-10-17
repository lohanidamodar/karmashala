/// Every container Karmashala makes is named with this prefix, and nothing
/// without it is ever started, stopped or deleted.
const kContainerPrefix = 'ks-';

/// The label every container Karmashala makes carries; delete checks it too.
const kContainerLabel = 'dev.karmashala.container';

/// The account created in each container. Fixed, never typed by a person.
const kContainerUser = 'dev';

/// The port range a container's sshd is published on, on the host's loopback.
const kContainerPortRange = (first: 41000, last: 41999);

/// The package manager a distribution's setup uses.
enum PackageManager { apt, dnf, apk, pacman }

/// The stock images a container can start from.
enum ContainerDistro {
  ubuntu2404('Ubuntu 24.04', 'ubuntu:24.04', PackageManager.apt),
  debian13('Debian 13', 'debian:13', PackageManager.apt),
  fedora('Fedora 42', 'fedora:42', PackageManager.dnf),
  alpine('Alpine 3.22', 'alpine:3.22', PackageManager.apk),
  arch('Arch Linux', 'archlinux:latest', PackageManager.pacman);

  const ContainerDistro(this.label, this.image, this.packageManager);

  final String label;
  final String image;
  final PackageManager packageManager;

  /// The distro an image names, or null for one Karmashala did not offer.
  static ContainerDistro? forImage(String image) {
    for (final distro in values) {
      if (distro.image == image) return distro;
    }
    return null;
  }
}

/// The agent CLIs a container can come with, installed with npm.
enum ContainerAgentCli {
  claude('Claude Code', '@anthropic-ai/claude-code', 18),
  codex('Codex', '@openai/codex', 18),
  gemini('Gemini CLI', '@google/gemini-cli', 20),
  copilot('GitHub Copilot', '@github/copilot', 22);

  const ContainerAgentCli(this.label, this.npmPackage, this.minimumNode);

  final String label;
  final String npmPackage;

  /// The oldest Node major version the CLI runs on.
  final int minimumNode;

  static ContainerAgentCli? byName(String name) {
    for (final cli in values) {
      if (cli.name == name) return cli;
    }
    return null;
  }
}

/// What a person asked a new container to be.
class ContainerSpec {
  const ContainerSpec({
    required this.name,
    required this.distro,
    required this.cpus,
    required this.memoryMb,
    this.agents = const [],
  });

  /// The machine's name as shown; also the container's, after the prefix.
  final String name;
  final ContainerDistro distro;
  final int cpus;
  final int memoryMb;
  final List<ContainerAgentCli> agents;

  /// The Docker container name.
  String get containerName => '$kContainerPrefix$name';

  /// The named volume holding the user's home, kept across a recreate.
  String get homeVolume => homeVolumeFor(containerName);

  /// The Node major version the chosen CLIs need; 0 when none are chosen.
  int get minimumNode => agents.fold(
    0,
    (most, cli) => cli.minimumNode > most ? cli.minimumNode : most,
  );
}

/// The home volume of the container named [containerName].
String homeVolumeFor(String containerName) => '$containerName-home';

final _namePattern = RegExp(r'^[a-z0-9][a-z0-9_.-]{0,39}$');

/// Why [name] cannot name a container, or null when it can. Docker's own rule,
/// narrowed to lower case so the name reads the same everywhere.
String? containerNameProblem(String name) {
  if (name.isEmpty) return 'Give it a name.';
  if (!_namePattern.hasMatch(name)) {
    return 'Use lower-case letters, digits, "-", "_" or ".", starting with a '
        'letter or digit, up to 40 characters.';
  }
  return null;
}

/// Why [spec] cannot be created on a host with [cores] and [freeMemoryMb],
/// or null. Unknown host figures are not held against it.
String? containerSpecProblem(
  ContainerSpec spec, {
  int? cores,
  int? freeMemoryMb,
}) {
  final named = containerNameProblem(spec.name);
  if (named != null) return named;
  if (spec.cpus < 1) return 'Give it at least one CPU.';
  if (cores != null && spec.cpus > cores) {
    return 'The host has $cores CPU${cores == 1 ? '' : 's'}.';
  }
  if (spec.memoryMb < 512) return 'Give it at least 512 MB of memory.';
  if (freeMemoryMb != null && spec.memoryMb > freeMemoryMb) {
    return 'The host has ${formatMemory(freeMemoryMb)} free.';
  }
  return null;
}

/// [mb] as a person reads it: `512 MB`, `4 GB`, `11.2 GB`.
String formatMemory(int mb) {
  if (mb < 1024) return '$mb MB';
  final gb = mb / 1024;
  final rounded = (gb * 10).round() / 10;
  return rounded == rounded.roundToDouble()
      ? '${rounded.round()} GB'
      : '$rounded GB';
}
