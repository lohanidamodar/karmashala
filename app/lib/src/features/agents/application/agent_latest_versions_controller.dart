import 'dart:async';
import 'dart:convert';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:karmashala_core/logging.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../data/agent_latest_version_fetcher.dart';
import 'agent_installations_controller.dart';
import 'agent_providers.dart';

/// How often an agent's latest release is asked for without the user asking.
///
/// Twelve hours, the same bound as [kVersionReadingFreshFor]: the installed
/// number is re-read on that cadence, so a latest number read more often would
/// only be compared against a stale install. It is a ceiling, not a timer —
/// nothing polls; the check runs when the Agents page is looked at and the
/// last one is older than this.
const Duration kLatestVersionCheckEvery = Duration(hours: 12);

/// The preference the last checks are kept under — a client preference like
/// the settings themselves, so no table and no schema change, and a restart
/// inside the twelve hours does not ask the registry again.
const String kAgentLatestVersionsKey = 'agents.latest_versions.v1';

final agentLatestVersionFetcherProvider = Provider<AgentLatestVersionFetcher>(
  (ref) => AgentLatestVersionFetcher(),
);

/// What the last check of one agent's latest release found.
class AgentLatestVersion {
  const AgentLatestVersion({
    required this.checkedAt,
    this.version,
    this.readAt,
    this.failure,
  });

  /// The newest version the source named — kept through a later failed
  /// check, so a registry that is down does not erase what is known.
  final String? version;

  /// When [version] was read. Older than [checkedAt] when the last check
  /// failed.
  final DateTime? readAt;

  /// When the last check was attempted, whether or not it worked — what the
  /// twelve-hour ceiling counts from, so a failing source is not hammered.
  final DateTime checkedAt;

  /// Why the last check produced nothing, or null when it worked. Recorded,
  /// not raised: a failed check is a line on the settings page, never a
  /// dialog.
  final String? failure;

  Map<String, Object?> toJson() => {
    'version': ?version,
    if (readAt case final at?) 'readAt': at.toUtc().toIso8601String(),
    'checkedAt': checkedAt.toUtc().toIso8601String(),
    'failure': ?failure,
  };

  static AgentLatestVersion? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final checkedAt = DateTime.tryParse('${json['checkedAt']}');
    if (checkedAt == null) return null;
    final version = json['version'];
    final failure = json['failure'];
    return AgentLatestVersion(
      checkedAt: checkedAt.toUtc(),
      version: version is String ? version : null,
      readAt: DateTime.tryParse('${json['readAt']}')?.toUtc(),
      failure: failure is String ? failure : null,
    );
  }
}

/// Every agent's last latest-release check, and which are being checked now.
class AgentLatestVersions {
  const AgentLatestVersions({
    this.byAgent = const {},
    this.checking = const {},
  });

  final Map<String, AgentLatestVersion> byAgent;
  final Set<String> checking;

  AgentLatestVersion? of(String agentId) => byAgent[agentId];

  bool isChecking(String agentId) => checking.contains(agentId);

  /// The latest version known for [agentId], or null.
  String? latestOf(String agentId) => byAgent[agentId]?.version;

  AgentLatestVersions copyWith({
    Map<String, AgentLatestVersion>? byAgent,
    Set<String>? checking,
  }) => AgentLatestVersions(
    byAgent: byAgent ?? this.byAgent,
    checking: checking ?? this.checking,
  );
}

/// **Whether each installed agent has a newer release, asked of the source
/// its descriptor declares** ([AgentSelfUpdate.latestVersion]).
///
/// Asks on its own at most once per [kLatestVersionCheckEvery] per agent, and
/// only while something watches it (the Agents and accounts page) — plus
/// whenever the user presses Check now. Only agents installed on some machine
/// and with a declared public source are asked about. Nothing is installed or
/// updated from here; the answer only colours the version on a machine row.
class AgentLatestVersionsController extends Notifier<AgentLatestVersions> {
  static final _log = AppLogger.named('agents.latest_version');

  /// What is stored, as last read or written here, so this client's own
  /// write does not come back as another client's news.
  String? _raw;

  @override
  AgentLatestVersions build() {
    final preferences = ref.watch(appPreferencesProvider);
    _raw = preferences.read(kAgentLatestVersionsKey);
    final changes = preferences.changes.listen((_) {
      final raw = preferences.read(kAgentLatestVersionsKey);
      if (raw == _raw) return;
      _raw = raw;
      state = state.copyWith(byAgent: _decode(raw));
    });
    ref.onDispose(changes.cancel);
    // An agent found on a machine later is checked then, not twelve hours on.
    ref.listen(agentInstallationsControllerProvider, (_, _) => _scheduleDue());
    _scheduleDue();
    return AgentLatestVersions(byAgent: _decode(_raw));
  }

  /// Checks every agent whose last check is older than
  /// [kLatestVersionCheckEvery] (or that was never checked).
  Future<void> checkDue() {
    final now = ref.read(clockProvider).nowUtc();
    return _check([
      for (final id in _checkable())
        if (_isDue(state.of(id), now)) id,
    ]);
  }

  /// Checks [agentId] now — or every checkable agent when null — whatever the
  /// age of the last check. The user asked.
  Future<void> checkNow({String? agentId}) => _check([
    for (final id in _checkable())
      if (agentId == null || id == agentId) id,
  ]);

  void _scheduleDue() => scheduleMicrotask(() {
    if (ref.mounted) unawaited(checkDue());
  });

  static bool _isDue(AgentLatestVersion? last, DateTime now) {
    if (last == null) return true;
    final age = now.difference(last.checkedAt);
    // A check "in the future" is a clock that moved; ask again.
    return age.isNegative || age >= kLatestVersionCheckEvery;
  }

  /// Agents installed somewhere whose descriptor declares a source.
  List<String> _checkable() {
    final registry = ref.read(agentRegistryProvider);
    final installed = {
      for (final install in ref.read(agentInstallationsControllerProvider))
        install.agentId,
    };
    return [
      for (final descriptor in registry.descriptors)
        if (installed.contains(descriptor.id) &&
            descriptor.launch.selfUpdate.latestVersion.isKnown)
          descriptor.id,
    ];
  }

  Future<void> _check(List<String> agentIds) async {
    final ids = [
      for (final id in agentIds)
        if (!state.isChecking(id)) id,
    ];
    if (ids.isEmpty) return;
    state = state.copyWith(checking: {...state.checking, ...ids});
    final registry = ref.read(agentRegistryProvider);
    final fetcher = ref.read(agentLatestVersionFetcherProvider);
    final results = await Future.wait([
      for (final id in ids) _checkOne(fetcher, registry, id),
    ]);
    if (!ref.mounted) return;
    final byAgent = {...state.byAgent};
    for (final (id, result) in results) {
      byAgent[id] = result;
    }
    state = AgentLatestVersions(
      byAgent: byAgent,
      checking: {...state.checking}..removeAll(ids),
    );
    final raw = _raw = jsonEncode({
      for (final entry in byAgent.entries) entry.key: entry.value.toJson(),
    });
    ref.read(appPreferencesProvider).write(kAgentLatestVersionsKey, raw);
  }

  Future<(String, AgentLatestVersion)> _checkOne(
    AgentLatestVersionFetcher fetcher,
    AgentRegistry registry,
    String agentId,
  ) async {
    final source = registry.byId(agentId)?.launch.selfUpdate.latestVersion;
    final previous = state.of(agentId);
    try {
      final version = await fetcher.fetch(
        source ?? const AgentLatestVersionSource.none(),
      );
      final now = ref.read(clockProvider).nowUtc();
      return (
        agentId,
        AgentLatestVersion(checkedAt: now, version: version, readAt: now),
      );
    } catch (e) {
      // Silent to the user beyond the settings line, but on the record.
      _log.info('Latest version of $agentId not checked: $e');
      return (
        agentId,
        AgentLatestVersion(
          checkedAt: ref.read(clockProvider).nowUtc(),
          version: previous?.version,
          readAt: previous?.readAt,
          failure: e is AgentLatestVersionException ? e.reason : '$e',
        ),
      );
    }
  }

  static Map<String, AgentLatestVersion> _decode(String? raw) {
    if (raw == null) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return const {};
      return {
        for (final entry in decoded.entries)
          entry.key: ?AgentLatestVersion.fromJson(entry.value),
      };
    } on FormatException {
      return const {};
    }
  }
}

final agentLatestVersionsProvider =
    NotifierProvider<AgentLatestVersionsController, AgentLatestVersions>(
      AgentLatestVersionsController.new,
    );

/// The version [install] should be updated to, or null when it is current,
/// unread or nothing newer is known.
///
/// The newer of the agent's latest release and the newest version another
/// machine runs: a machine can have updated itself since the last registry
/// check, and a registry that could not be asked still leaves the
/// machine-to-machine comparison standing.
String? agentUpdateTarget(
  AgentInstallation install, {
  required String? latest,
  required String? newestOnMachines,
}) {
  final installed = install.version;
  if (installed == null) return null;
  final candidates = [?latest, ?newestOnMachines];
  if (candidates.isEmpty) return null;
  final target = candidates.reduce(
    (a, b) => compareAgentVersions(a, b) >= 0 ? a : b,
  );
  return isAgentVersionBehind(installed, target) ? target : null;
}
