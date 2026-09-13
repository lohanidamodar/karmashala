/// **What a session started in one directory would be given** — its MCP servers
/// and its skills, read off configuration files, each row naming where it came
/// from.
///
/// Never *what a running session has*: an agent binds its servers when it
/// starts and owns those processes (§19). Everything here is a reading of
/// files, and it carries the age of that reading like every other one.
library;

import 'package:agent_cli/descriptors.dart';


/// Where one entry was read, which is also what the user would edit to change
/// it. Ordered most specific first, which is the order the panel draws.
enum AgentContextOrigin {
  /// Written or injected by Karmashala itself. Marked, because a list that did
  /// not say so would make the app's own entries look like the user's.
  karmashala,

  /// A file inside the checkout, so it travels with the project.
  project,

  /// The user's own file, for this directory only.
  directory,

  /// The user's own file, for every directory on this machine.
  user,
}

/// Whether an entry would actually be bound, when the agent asks first.
enum AgentContextStanding {
  /// Nothing stands between it and the session.
  taken,

  /// The agent will ask before binding it — a project file names it and the
  /// user has not answered yet.
  awaitingApproval,

  /// The user said no to it here.
  refused,
}

/// One MCP server or one skill.
class AgentContextEntry {
  const AgentContextEntry({
    required this.name,
    required this.origin,
    required this.source,
    this.detail,
    this.standing = AgentContextStanding.taken,
  });

  final String name;
  final AgentContextOrigin origin;

  /// The file or directory it was read from, spelled the way the agent spells
  /// it. Empty for [AgentContextOrigin.karmashala], which names no file the
  /// user would edit.
  final String source;

  /// One line about it — a transport, a skill's own description. Never a
  /// config value: server environments hold credentials.
  final String? detail;

  final AgentContextStanding standing;

  @override
  bool operator ==(Object other) =>
      other is AgentContextEntry &&
      other.name == name &&
      other.origin == origin &&
      other.source == source &&
      other.detail == detail &&
      other.standing == standing;

  @override
  int get hashCode => Object.hash(name, origin, source, detail, standing);

  @override
  String toString() => 'AgentContextEntry($name from ${origin.name})';
}

/// Why a reading holds nothing, when the answer is not "there is nothing".
enum AgentContextAbsence {
  /// No session is on screen to report on.
  noSession,

  /// Nobody has established where this agent keeps its configuration, so it has
  /// not been read. **Not the same as having none.**
  agentUndeclared,

  /// The directory is on a machine this app cannot read files on from here —
  /// an SSH host. Asking means dialling it, which §20 keeps off a launch.
  environmentNotReadable,

  /// It has not been read yet.
  notRead,
}

/// One reading of what a session would be given, with its age.
class AgentContextReading {
  const AgentContextReading({
    required this.mcpServers,
    required this.skills,
    required this.readAt,
    this.notes = const [],
  }) : absence = null,
       refusal = '';

  /// Nothing was read, and [absence] says which nothing it is.
  const AgentContextReading.absent(this.absence, {this.refusal = ''})
    : mcpServers = const [],
      skills = const [],
      readAt = null,
      notes = const [];

  final List<AgentContextEntry> mcpServers;
  final List<AgentContextEntry> skills;

  /// When the files were read. Null exactly when nothing was.
  final DateTime? readAt;

  /// What could not be read, in one sentence each — a file that would not
  /// parse, a directory that would not list. Never silent: a skipped source is
  /// a shorter list that looks complete.
  final List<String> notes;

  final AgentContextAbsence? absence;

  /// The more specific sentence behind [absence], when there is one.
  final String refusal;

  bool get wasRead => readAt != null;
}

/// The name Karmashala's own server is given in the config it writes for a
/// launch. A constant here so the panel and `SessionMcpConfigs` agree.
const String kKarmashalaMcpServerName = 'karmashala';

/// **Where a row came from, in one line** — the file the user would edit, or
/// the fact that Karmashala put it there.
///
/// Provenance is the point of the panel: a list that did not say which entries
/// are the app's own would make them look like something the user configured.
String describeProvenance(AgentContextEntry entry) {
  final standing = switch (entry.standing) {
    AgentContextStanding.taken => '',
    AgentContextStanding.awaitingApproval => ' · you have not approved it yet',
    AgentContextStanding.refused => ' · you turned it off here',
  };
  return switch (entry.origin) {
        AgentContextOrigin.karmashala => entry.source.isEmpty
            ? 'added by Karmashala at launch'
            : 'installed by Karmashala · ${entry.source}',
        AgentContextOrigin.project => '${entry.source} · in this checkout',
        AgentContextOrigin.directory => '${entry.source} · this directory only',
        AgentContextOrigin.user => entry.source,
      } +
      standing;
}

/// The files one agent would read for a session in [directory].
class AgentConfigSources {
  const AgentConfigSources({
    required this.directory,
    this.projectConfig,
    this.projectConfigPath = '',
    this.userConfig,
    this.userConfigPath = '',
  });

  /// The working directory **as the agent spells it**, which is also the key
  /// the user file files per-directory settings under.
  final String directory;

  /// The parsed project file, or null when it is absent or was not read.
  final Map<String, Object?>? projectConfig;
  final String projectConfigPath;

  /// The parsed user file, or null when it is absent or was not read.
  final Map<String, Object?>? userConfig;
  final String userConfigPath;
}

/// **The servers a session started in [sources]'s directory would be offered**,
/// project first, then this directory, then the machine.
///
/// [injectsOwnServer] is what the *app* adds at launch, which is in none of
/// these files: it is a flag on the agent's descriptor, not a reading.
///
/// A name in two scopes is kept twice on purpose. Which one an agent prefers is
/// not measured here, and dropping one would be that claim made silently.
List<AgentContextEntry> mcpServersFrom(
  AgentMcpConfigSpec spec,
  AgentConfigSources sources, {
  bool injectsOwnServer = false,
}) {
  final entries = <AgentContextEntry>[
    if (injectsOwnServer)
      const AgentContextEntry(
        name: kKarmashalaMcpServerName,
        origin: AgentContextOrigin.karmashala,
        source: '',
        detail: 'added to this launch, for this session only',
      ),
  ];
  if (!spec.isDeclared) return entries;

  final directoryEntry = _directoryEntry(spec, sources);
  final approved = _stringSet(directoryEntry, spec.approvedKey);
  final refused = _stringSet(directoryEntry, spec.refusedKey);

  for (final server in _serversAt(
    sources.projectConfig,
    spec.projectServersPath,
  ).entries) {
    entries.add(
      AgentContextEntry(
        name: server.key,
        origin: AgentContextOrigin.project,
        source: sources.projectConfigPath,
        detail: _transportOf(server.value),
        standing: !spec.asksApproval || approved.contains(server.key)
            ? AgentContextStanding.taken
            : refused.contains(server.key)
            ? AgentContextStanding.refused
            : AgentContextStanding.awaitingApproval,
      ),
    );
  }

  for (final server
      in _serversAt(directoryEntry, spec.perProjectServersPath).entries) {
    entries.add(
      AgentContextEntry(
        name: server.key,
        origin: AgentContextOrigin.directory,
        source: sources.userConfigPath,
        detail: _transportOf(server.value),
      ),
    );
  }

  for (final server in _serversAt(
    sources.userConfig,
    spec.userServersPath,
  ).entries) {
    entries.add(
      AgentContextEntry(
        name: server.key,
        origin: AgentContextOrigin.user,
        source: sources.userConfigPath,
        detail: _transportOf(server.value),
      ),
    );
  }
  return entries;
}

/// The user file's entry for this directory, or null when there is none.
Map<String, Object?>? _directoryEntry(
  AgentMcpConfigSpec spec,
  AgentConfigSources sources,
) {
  if (!spec.readsPerProjectServers) return null;
  final byDirectory = sources.userConfig?[spec.perProjectKey];
  if (byDirectory is! Map) return null;
  final entry = byDirectory[sources.directory];
  return entry is Map ? entry.cast<String, Object?>() : null;
}

Map<String, Object?> _serversAt(Map<String, Object?>? config, List<String> at) {
  Object? here = config;
  if (here == null || at.isEmpty) return const {};
  for (final key in at) {
    if (here is! Map) return const {};
    here = here[key];
  }
  return here is Map ? here.cast<String, Object?>() : const {};
}

Set<String> _stringSet(Map<String, Object?>? config, String key) {
  if (config == null || key.isEmpty) return const {};
  final value = config[key];
  return value is List ? {for (final v in value) '$v'} : const {};
}

/// How a server is reached, and nothing else. A server's `env` holds tokens —
/// this panel is read by whoever is looking at the screen.
String? _transportOf(Object? server) {
  if (server is! Map) return null;
  final type = server['type'];
  if (type is String && type.isNotEmpty) return type;
  return server.containsKey('url') ? 'http' : 'stdio';
}
