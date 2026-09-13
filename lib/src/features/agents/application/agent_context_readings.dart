import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_agent_reporting/skills.dart';
import 'package:path/path.dart' as p;
import 'package:riverpod/riverpod.dart';

import '../../../core/process/command_runner_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../domain/agent_context.dart';
import 'agent_providers.dart';

/// How long a reading is worth reusing. Configuration files move when somebody
/// edits one, which is rare and deliberate — the same reasoning as
/// `kToolchainReadingFreshFor`.
const Duration kAgentContextFreshFor = Duration(minutes: 5);

/// What has to be known before anything can be read: which agent, in which
/// environment, for which directory.
class AgentContextTarget {
  const AgentContextTarget({
    required this.agentId,
    required this.environmentId,
    required this.directory,
  });

  final String agentId;
  final String environmentId;

  /// The directory **as the agent spells it** — the key the user's own file
  /// files per-directory settings under.
  final String directory;

  String get key => '$agentId|$environmentId|$directory';
}

/// **What a session started here would be given**, read on demand and kept with
/// its age. In memory, like `ToolchainReadings`: a reading persisted across
/// runs would be a claim about files nobody has opened this launch.
class AgentContextReadings extends Notifier<Map<String, AgentContextReading>> {
  @override
  Map<String, AgentContextReading> build() => const {};

  AgentContextReading? cached(AgentContextTarget target) => state[target.key];

  /// Reads [target]'s files, reusing a reading that is still fresh unless
  /// [force] says to look again. **Never throws**: every escape becomes a note
  /// on the reading, because these are somebody's real files.
  Future<AgentContextReading> readFor(
    AgentContextTarget target, {
    bool force = false,
  }) async {
    final now = ref.read(clockProvider).nowUtc();
    final held = state[target.key];
    if (!force &&
        held != null &&
        held.readAt != null &&
        now.difference(held.readAt!) < kAgentContextFreshFor) {
      return held;
    }

    final reading = await _read(target, now);
    state = {...state, target.key: reading};
    return reading;
  }

  void forget(AgentContextTarget target) {
    if (!state.containsKey(target.key)) return;
    state = {...state}..remove(target.key);
  }

  Future<AgentContextReading> _read(
    AgentContextTarget target,
    DateTime now,
  ) async {
    final descriptor = ref.read(agentRegistryProvider).byId(target.agentId);
    if (descriptor == null) {
      return const AgentContextReading.absent(
        AgentContextAbsence.agentUndeclared,
        refusal: 'This session runs a CLI this build has no descriptor for.',
      );
    }

    final environments = ref.read(executionEnvironmentDaoProvider);
    final environment = environments.getById(target.environmentId);
    if (environment == null) {
      return const AgentContextReading.absent(AgentContextAbsence.notRead);
    }

    // §20: an SSH host is somebody else's machine, and reading its files means
    // dialling it. The panel says so rather than coming up empty.
    if (environment.kind == EnvironmentKind.ssh) {
      return AgentContextReading.absent(
        AgentContextAbsence.environmentNotReadable,
        refusal:
            'This directory is on ${environment.name}, reached over SSH. Its '
            'files are not read from here.',
      );
    }

    final notes = <String>[];
    final localDirectory = _readableDirectory(environment, target.directory);
    if (localDirectory == null) {
      notes.add(
        'The working directory could not be spelled for this machine, so '
        'nothing in the checkout was read.',
      );
    }

    final storeHome = await _storeHome(environment, descriptor.id);
    if (storeHome == null) {
      notes.add(
        'No ${descriptor.displayName} store was found in ${environment.name}, '
        'so the user-level configuration was not read.',
      );
    }

    final spec = descriptor.mcpConfig;
    Map<String, Object?>? projectConfig;
    var projectConfigPath = '';
    if (spec.projectFileName.isNotEmpty && localDirectory != null) {
      projectConfigPath = p.join(target.directory, spec.projectFileName);
      projectConfig = _readJson(
        p.join(localDirectory, spec.projectFileName),
        onProblem: notes.add,
        label: projectConfigPath,
      );
    }
    Map<String, Object?>? userConfig;
    var userConfigPath = '';
    if (spec.userFileName.isNotEmpty && storeHome != null) {
      final resolved = p.normalize(p.join(storeHome, spec.userFileName));
      userConfigPath = p.basename(resolved);
      userConfig = _readJson(resolved, onProblem: notes.add, label: resolved);
    }

    final servers = spec.isDeclared
        ? mcpServersFrom(
            spec,
            AgentConfigSources(
              directory: target.directory,
              projectConfig: projectConfig,
              projectConfigPath: projectConfigPath,
              userConfig: userConfig,
              userConfigPath: userConfigPath,
            ),
            injectsOwnServer: descriptor.launch.mcp.isSupported,
          )
        : <AgentContextEntry>[
            if (descriptor.launch.mcp.isSupported)
              const AgentContextEntry(
                name: kKarmashalaMcpServerName,
                origin: AgentContextOrigin.karmashala,
                source: '',
                detail: 'added to this launch, for this session only',
              ),
          ];
    if (!spec.isDeclared) {
      notes.add(
        spec.refusal.isEmpty
            ? 'Nobody has established where ${descriptor.displayName} reads its '
                  'own MCP servers, so the rest has not been read.'
            : spec.refusal,
      );
    }

    final skills = await _skills(
      descriptor,
      storeHome: storeHome,
      localDirectory: localDirectory,
      directory: target.directory,
      onProblem: notes.add,
    );

    return AgentContextReading(
      mcpServers: servers,
      skills: skills,
      readAt: now,
      notes: notes,
    );
  }

  /// The directory spelled the way *this* process opens it — unchanged on the
  /// machine we run on, a UNC share for a WSL distribution.
  String? _readableDirectory(
    ExecutionEnvironment environment,
    String directory,
  ) {
    if (isLocalHost(environment.kind)) return directory;
    if (environment.kind != EnvironmentKind.wsl) return null;
    try {
      ExecutionEnvironment? windows;
      for (final candidate in ref
          .read(executionEnvironmentDaoProvider)
          .getAll()) {
        if (candidate.kind == EnvironmentKind.windowsNative) {
          windows = candidate;
          break;
        }
      }
      if (windows == null) return null;
      return ref
          .read(pathTranslatorProvider)
          .translate(
            EnvironmentPath(environmentId: environment.id, path: directory),
            from: environment,
            to: windows,
          )
          .path;
    } on Object {
      return null;
    }
  }

  /// Where the agent keeps its per-user configuration in [environment].
  ///
  /// Only this environment is located, plus the Windows row a WSL home has to
  /// be translated through — locating every one of them would start every
  /// distribution to open one file.
  Future<String?> _storeHome(
    ExecutionEnvironment environment,
    String agentId,
  ) async {
    try {
      final all = ref.read(executionEnvironmentDaoProvider).getAll();
      final needed = <ExecutionEnvironment>[
        environment,
        for (final candidate in all)
          if (candidate.kind == EnvironmentKind.windowsNative &&
              candidate.id != environment.id)
            candidate,
      ];
      final stores = await ref.read(cliStoreLocatorProvider).locate(needed);
      for (final store in stores) {
        if (store.environmentId != environment.id) continue;
        return store.homesByAgentId[agentId];
      }
    } on Object {
      // A distribution that would not answer. Reported as a note by the caller.
    }
    return null;
  }

  Map<String, Object?>? _readJson(
    String path, {
    required void Function(String) onProblem,
    required String label,
  }) {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map) return decoded.cast<String, Object?>();
      onProblem('$label is not a JSON object, so nothing was read from it.');
    } on Object {
      onProblem('$label could not be read, so what it names is unknown.');
    }
    return null;
  }

  Future<List<AgentContextEntry>> _skills(
    AgentDescriptor descriptor, {
    required String? storeHome,
    required String? localDirectory,
    required String directory,
    required void Function(String) onProblem,
  }) async {
    final support = descriptor.skills;
    final entries = <AgentContextEntry>[];
    if (!support.isSupported) {
      onProblem(
        support.refusal.isEmpty
            ? 'Nobody has established where ${descriptor.displayName} reads a '
                  'skill, so none were looked for.'
            : support.refusal,
      );
      return entries;
    }

    if (localDirectory != null && support.projectDirectorySegments.isNotEmpty) {
      entries.addAll(
        _skillsUnder(
          p.joinAll([localDirectory, ...support.projectDirectorySegments]),
          shownAs: p.joinAll([directory, ...support.projectDirectorySegments]),
          origin: AgentContextOrigin.project,
          onProblem: onProblem,
        ),
      );
    }

    final userRoot = storeHome == null
        ? null
        : const AgentSkillInstaller().rootFor(descriptor, storeHome);
    if (userRoot != null) {
      entries.addAll(
        _skillsUnder(
          userRoot,
          shownAs: p.joinAll(['~', ...support.directorySegments]),
          origin: AgentContextOrigin.user,
          onProblem: onProblem,
        ),
      );
    }
    return entries;
  }

  /// One skills root, listed. A directory holding no `SKILL.md` is not a skill
  /// and is passed over rather than counted.
  List<AgentContextEntry> _skillsUnder(
    String root, {
    required String shownAs,
    required AgentContextOrigin origin,
    required void Function(String) onProblem,
  }) {
    final entries = <AgentContextEntry>[];
    try {
      final directory = Directory(root);
      if (!directory.existsSync()) return entries;
      for (final child in directory.listSync()) {
        if (child is! Directory) continue;
        final file = File(p.join(child.path, AgentSkillInstaller.fileName));
        if (!file.existsSync()) continue;
        final text = file.readAsStringSync();
        entries.add(
          AgentContextEntry(
            name: p.basename(child.path),
            origin: text.contains(karmashalaSkillMarker)
                ? AgentContextOrigin.karmashala
                : origin,
            source: shownAs,
            detail: skillDescriptionIn(text),
          ),
        );
      }
    } on Object {
      onProblem('$shownAs could not be listed, so its skills are unknown.');
    }
    entries.sort((a, b) => a.name.compareTo(b.name));
    return entries;
  }
}

final agentContextReadingsProvider =
    NotifierProvider<AgentContextReadings, Map<String, AgentContextReading>>(
      AgentContextReadings.new,
    );

/// Whether a target is being read right now, so its row can say so.
class AgentContextReadsRunning extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void start(String key) => state = {...state, key};
  void finish(String key) => state = {...state}..remove(key);
}

final agentContextReadsRunningProvider =
    NotifierProvider<AgentContextReadsRunning, Set<String>>(
      AgentContextReadsRunning.new,
    );

/// Reads [target] and keeps the running set honest whatever happens.
Future<void> readAgentContext(
  ProviderContainer container,
  AgentContextTarget target, {
  bool force = false,
}) async {
  final running = container.read(agentContextReadsRunningProvider.notifier);
  if (container.read(agentContextReadsRunningProvider).contains(target.key)) {
    return;
  }
  running.start(target.key);
  try {
    await container
        .read(agentContextReadingsProvider.notifier)
        .readFor(target, force: force);
  } finally {
    running.finish(target.key);
  }
}

/// The `description:` a `SKILL.md` declares, or null when it declares none.
///
/// The frontmatter's own folded scalar included — `KarmashalaSkill.render`
/// writes every one of ours that way.
String? skillDescriptionIn(String text) {
  final lines = const LineSplitter().convert(text);
  if (lines.isEmpty || lines.first.trim() != '---') return null;
  for (var i = 1; i < lines.length; i++) {
    final line = lines[i];
    if (line.trim() == '---') return null;
    if (!line.startsWith('description:')) continue;
    final inline = line.substring('description:'.length).trim();
    if (inline.isNotEmpty && inline != '>-' && inline != '>' && inline != '|') {
      return inline;
    }
    final folded = <String>[];
    for (var j = i + 1; j < lines.length; j++) {
      final next = lines[j];
      if (next.trim() == '---' || !next.startsWith(' ')) break;
      folded.add(next.trim());
    }
    return folded.isEmpty ? null : folded.join(' ');
  }
  return null;
}
