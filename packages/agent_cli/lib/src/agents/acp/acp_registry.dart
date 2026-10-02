import 'dart:convert';

/// A command line the registry resolved for one platform.
typedef AcpLaunchCommand = ({String command, List<String> args});

/// The public ACP agent registry (https://agentclientprotocol.com), parsed.
///
/// Pure parsing: [fetch] takes the HTTP getter so no test reaches the network.
/// Lenient on purpose — the registry gains fields and platforms between
/// releases, and an entry this build cannot fully read is still listed.
class AcpRegistryCatalog {
  const AcpRegistryCatalog(this.agents);

  /// Where the current registry is published.
  static const String registryUrl =
      'https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json';

  final List<AcpRegistryEntry> agents;

  /// Throws [FormatException] for a document that is not a JSON object.
  /// A missing or malformed `agents` list reads as no agents.
  static AcpRegistryCatalog parse(String json) {
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('ACP registry is not a JSON object');
    }
    final agents = decoded['agents'];
    return AcpRegistryCatalog([
      if (agents is List)
        for (final entry in agents)
          if (entry is Map<String, Object?>) AcpRegistryEntry.fromJson(entry),
    ]);
  }

  static Future<AcpRegistryCatalog> fetch(
    Future<String> Function(Uri url) get,
  ) async => parse(await get(Uri.parse(registryUrl)));

  AcpRegistryEntry? byId(String id) {
    for (final agent in agents) {
      if (agent.id == id) return agent;
    }
    return null;
  }
}

/// One agent in the registry. Every field is nullable because the registry
/// does not promise any of them, and `null` is read as "not said".
class AcpRegistryEntry {
  const AcpRegistryEntry({
    this.id,
    this.name,
    this.version,
    this.description,
    this.npx,
    this.binaries = const {},
    this.icon,
  });

  factory AcpRegistryEntry.fromJson(Map<String, Object?> json) {
    final distribution = json['distribution'];
    final npx = distribution is Map<String, Object?>
        ? distribution['npx']
        : null;
    final binary = distribution is Map<String, Object?>
        ? distribution['binary']
        : null;
    return AcpRegistryEntry(
      id: _string(json['id']),
      name: _string(json['name']),
      version: _string(json['version']),
      description: _string(json['description']),
      npx: npx is Map<String, Object?>
          ? AcpNpxDistribution.fromJson(npx)
          : null,
      icon: _string(json['icon']),
      binaries: {
        if (binary is Map<String, Object?>)
          for (final platform in binary.entries)
            if (platform.value case final Map<String, Object?> spec)
              platform.key: AcpBinaryDistribution.fromJson(spec),
      },
    );
  }

  final String? id;
  final String? name;
  final String? version;
  final String? description;

  /// Where the entry's icon is published — an SVG under the registry's CDN.
  final String? icon;

  /// The npm distribution, when the entry has one.
  final AcpNpxDistribution? npx;

  /// Prebuilt binaries by platform key (`darwin-aarch64`, `linux-x86_64`,
  /// `windows-x86_64`, …). Platforms this build has never heard of are kept.
  final Map<String, AcpBinaryDistribution> binaries;

  /// What a picker shows for this entry.
  String get label => name ?? id ?? 'Unnamed agent';

  /// How to start this agent as it stands: `npx -y <package> …` when the
  /// entry has an npm distribution — it runs anywhere node does — else null.
  /// A binary distribution is not a launch: its command (`./agent`) names a
  /// file inside an archive that has to be installed first, and the launch
  /// is then the installed path.
  AcpLaunchCommand? launchFor(String platform) {
    final npx = this.npx;
    if (npx?.package == null) return null;
    return (command: 'npx', args: ['-y', npx!.package!, ...npx.args]);
  }
}

/// `distribution.npx`: the package `npx -y` runs, with any arguments.
class AcpNpxDistribution {
  const AcpNpxDistribution({
    this.package,
    this.args = const [],
    this.env = const {},
  });

  factory AcpNpxDistribution.fromJson(Map<String, Object?> json) =>
      AcpNpxDistribution(
        package: _string(json['package']),
        args: _strings(json['args']),
        env: _stringMap(json['env']),
      );

  /// The npm package, usually pinned (`@scope/name@1.2.3`).
  final String? package;
  final List<String> args;
  final Map<String, String> env;
}

/// `distribution.binary.<platform>`: an archive to download and the command
/// inside it. The registry spells the command `cmd`; `command` is read too.
class AcpBinaryDistribution {
  const AcpBinaryDistribution({
    this.archive,
    this.sha256,
    this.command,
    this.args = const [],
    this.env = const {},
  });

  factory AcpBinaryDistribution.fromJson(Map<String, Object?> json) =>
      AcpBinaryDistribution(
        archive: _string(json['archive']),
        sha256: _string(json['sha256']),
        command: _string(json['cmd'] ?? json['command']),
        args: _strings(json['args']),
        env: _stringMap(json['env']),
      );

  final String? archive;
  final String? sha256;
  final String? command;
  final List<String> args;
  final Map<String, String> env;
}

String? _string(Object? value) => value is String ? value : null;

List<String> _strings(Object? value) => [
  if (value is List)
    for (final item in value)
      if (item is String) item,
];

Map<String, String> _stringMap(Object? value) => {
  if (value is Map)
    for (final entry in value.entries)
      if (entry.key is String && entry.value is String)
        entry.key as String: entry.value as String,
};
