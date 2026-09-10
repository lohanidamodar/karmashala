import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../../core/util/clock_provider.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../environments/application/environment_providers.dart';
import 'package:agent_cli/process.dart';
import '../../mcp/agent_skills.dart';
import '../data/agent_skill_installer.dart';
import 'package:agent_cli/descriptors.dart';
import 'agent_providers.dart';

/// One agent's skills in one environment, or the reason there are none.
class AgentSkillInstallation {
  const AgentSkillInstallation({
    required this.agentId,
    required this.environmentId,
    required this.installed,
    required this.declared,
    this.root,
    this.agentPresent = true,
    this.unknown = false,
    this.skippedBecause,
  });

  final String agentId;
  final String environmentId;

  /// How many skills are on disk **right now** spelling this build's bytes.
  final int installed;

  /// How many this build would install here. Zero for an agent that declares
  /// no skills root.
  final int declared;

  /// Where they went, so the panel can name a real directory rather than
  /// describe one.
  final String? root;

  /// Whether this agent has a store here at all. `false` is the one incomplete
  /// row that is not a fault: there was no agent to teach.
  final bool agentPresent;

  /// Whether this row is an admission of ignorance rather than a result: the
  /// store home did not answer inside the budget.
  final bool unknown;

  /// Why there are fewer than [declared], in the host's words. `null` when
  /// [complete].
  final String? skippedBecause;

  bool get complete => declared > 0 && installed == declared;
}

/// What the last skill sweep did, and when it read that.
class AgentSkillInstallationReport {
  const AgentSkillInstallationReport(this.results, {this.checkedAt});

  /// **Before any sweep has finished**, which is not a sweep that found nothing.
  /// The panel says the skills are not installed *yet* rather than saying
  /// nothing, which would read as "they are there".
  static const AgentSkillInstallationReport unswept =
      AgentSkillInstallationReport(<AgentSkillInstallation>[]);

  final List<AgentSkillInstallation> results;

  /// When the sweep reported. `null` only for [unswept], which is what makes
  /// the age of the reading showable rather than assumed.
  final DateTime? checkedAt;

  bool get swept => checkedAt != null;

  /// Rows that hold every skill this build ships.
  List<AgentSkillInstallation> get complete =>
      results.where((r) => r.complete).toList();

  /// Rows that do not, and are somebody's problem rather than an absent agent.
  Map<String, String> get incompleteByAgent => {
    for (final result in results)
      if (!result.complete && result.agentPresent && !result.unknown)
        result.agentId: ?result.skippedBecause,
  };

  Map<String, String> get unknownByAgent => {
    for (final result in results)
      if (result.unknown) result.agentId: ?result.skippedBecause,
  };
}

/// Ambient state, written after each sweep by whoever ran it.
class AgentSkillInstallationReportController
    extends Notifier<AgentSkillInstallationReport> {
  @override
  AgentSkillInstallationReport build() => AgentSkillInstallationReport.unswept;

  void set(AgentSkillInstallationReport next) => state = next;
}

final agentSkillInstallationReportProvider =
    NotifierProvider<
      AgentSkillInstallationReportController,
      AgentSkillInstallationReport
    >(AgentSkillInstallationReportController.new);

/// Writes Karmashala's skills into the agent CLIs at startup, and takes them
/// back out when asked.
///
/// Deliberately thinner than [AgentHookInstallationService]: a skill has no
/// address, so nothing is unreachable; no token, so nothing is retired on the
/// way out; and no config file of the user's to splice, so nothing here can lose
/// the race that made hook entries constants. What it keeps is the shape — every
/// located store, every agent that declares a skills root, one row each, bounded
/// so a `\\wsl.localhost` share that stops answering costs one row.
class AgentSkillInstallationService {
  AgentSkillInstallationService(
    this._ref, {
    AppLogger? logger,
    Duration? storeBudget,
    List<KarmashalaSkill>? skills,
  }) : _log = logger ?? AppLogger.named('agent-skills'),
       _storeBudget = storeBudget ?? defaultStoreBudget,
       _skills = skills ?? kKarmashalaSkills;

  /// The same ten seconds [AgentHookInstallationService.defaultStoreBudget]
  /// argues for: the first touch of a WSL store home over the share starts a
  /// stopped distribution, so the honest failure here is slow, not broken.
  static const Duration defaultStoreBudget = Duration(seconds: 10);

  final Ref _ref;
  final AppLogger _log;
  final Duration _storeBudget;
  final List<KarmashalaSkill> _skills;

  /// Every sweep this service has started, so a quit can give up on all of
  /// them at once. Cleared each sweep; see [abandon].
  final List<SkillSweepDeadline> _deadlines = <SkillSweepDeadline>[];

  /// Stops every sweep in flight from touching the filesystem again — **what
  /// shutdown calls instead of awaiting**. Each `SKILL.md` is staged and renamed
  /// and the bytes are constant, so there is nothing half-written to finish and
  /// no grace period is owed.
  void abandon() {
    for (final deadline in _deadlines) {
      deadline.giveUp();
    }
  }

  Future<List<AgentSkillInstallation>> installAll() => _forEachStore(
    verb: 'install',
    removing: false,
    act: (installer, descriptor, home, deadline) => installer.install(
      descriptor: descriptor,
      storeHome: home,
      skills: _skills,
      deadline: deadline,
    ),
  );

  /// Removes every skill [installAll] wrote. The complete removal, for a user
  /// who wants this app out of their agents' configuration.
  ///
  /// Nothing calls this on the way out, by decision: a skill has no volatile
  /// half, and putting identical bytes back next start is the race
  /// `AgentHookInstaller` was rewritten to avoid.
  Future<List<AgentSkillInstallation>> uninstallAll() => _forEachStore(
    verb: 'uninstall',
    removing: true,
    act: (installer, descriptor, home, deadline) => installer.uninstall(
      descriptor: descriptor,
      storeHome: home,
      deadline: deadline,
    ),
  );

  Future<List<AgentSkillInstallation>> _forEachStore({
    required String verb,
    required bool removing,
    required Future<void> Function(
      AgentSkillInstaller installer,
      AgentDescriptor descriptor,
      String home,
      SkillSweepDeadline deadline,
    )
    act,
  }) async {
    final environments = _ref.read(executionEnvironmentDaoProvider).getAll();
    if (environments.isEmpty) return const [];

    // The previous sweep's tokens are spent; a new one starts its own so
    // `abandon` never has to walk a list that only grows.
    _deadlines.clear();
    final stores = await _ref
        .read(cliStoreLocatorProvider)
        .locate(environments);
    final installer = _ref.read(agentSkillInstallerProvider);
    final registry = _ref.read(agentRegistryProvider);

    // Every (agent, store home) pair at once: the pairs are independent — each
    // agent declares its own root — and one of them is commonly a share whose
    // latency belongs to a distribution rather than to this app.
    final pending = <Future<AgentSkillInstallation>>[];
    for (final store in stores) {
      for (final descriptor in registry.descriptors) {
        final home = store.homesByAgentId[descriptor.id];
        if (home == null) continue;
        // One per pair, held here so both the bound and a quit can give up on
        // it — see [SkillSweepDeadline].
        final deadline = SkillSweepDeadline();
        _deadlines.add(deadline);
        pending.add(
          _bounded(
            agentId: descriptor.id,
            environmentId: store.environmentId,
            home: home,
            deadline: deadline,
            body: () => _oneStore(
              verb: verb,
              removing: removing,
              act: act,
              installer: installer,
              descriptor: descriptor,
              environmentId: store.environmentId,
              home: home,
              deadline: deadline,
            ),
          ),
        );
      }
    }
    return Future.wait(pending);
  }

  Future<AgentSkillInstallation> _bounded({
    required String agentId,
    required String environmentId,
    required String home,
    required SkillSweepDeadline deadline,
    required Future<AgentSkillInstallation> Function() body,
  }) => body().timeout(
    _storeBudget,
    onTimeout: () {
      // **The wait is what the bound ends; the work has to be told.** Otherwise
      // the install goes on creating directories under a store home the app has
      // already reported as unknown.
      deadline.giveUp();
      final budget = _storeBudget.inSeconds >= 1
          ? '${_storeBudget.inSeconds}s'
          : '${_storeBudget.inMilliseconds} ms';
      _log.warning(
        'The store home for $agentId in '
        '${describeEnvironmentId(environmentId)} did not answer within '
        '$budget ($home); whether its skills are installed is unknown for '
        'this run.',
      );
      return AgentSkillInstallation(
        agentId: agentId,
        environmentId: environmentId,
        installed: 0,
        declared: _skills.length,
        unknown: true,
        skippedBecause:
            'the store home did not answer within $budget, so whether the '
            'skills are there is unknown',
      );
    },
  );

  /// One (agent, store home) pair. Never throws: every escape becomes a row,
  /// because the directory is somebody's real home and the launch goes on
  /// without it.
  Future<AgentSkillInstallation> _oneStore({
    required String verb,
    required bool removing,
    required Future<void> Function(
      AgentSkillInstaller installer,
      AgentDescriptor descriptor,
      String home,
      SkillSweepDeadline deadline,
    )
    act,
    required AgentSkillInstaller installer,
    required AgentDescriptor descriptor,
    required String environmentId,
    required String home,
    required SkillSweepDeadline deadline,
  }) async {
    final root = installer.rootFor(descriptor, home);
    if (root == null) {
      // An agent nobody has established a skills root for. It gets nothing
      // written and says why, in the host's words when there are any.
      final refusal = descriptor.skills.refusal;
      return AgentSkillInstallation(
        agentId: descriptor.id,
        environmentId: environmentId,
        installed: 0,
        declared: 0,
        skippedBecause: refusal.isEmpty
            ? 'nobody has established where this CLI discovers a skill, so '
                  'nothing is written into its configuration'
            : refusal,
      );
    }
    try {
      await act(installer, descriptor, home, deadline);
      final present = await installer.installedSkills(
        descriptor: descriptor,
        storeHome: home,
        skills: _skills,
      );
      final absent = !await installer.storeIsPresent(home);
      // A removal is complete when nothing of ours is left, so it declares
      // nothing and the count it reports is what survived — which is zero, or
      // a file we could not delete.
      final declared = removing ? 0 : _skills.length;
      return AgentSkillInstallation(
        agentId: descriptor.id,
        environmentId: environmentId,
        installed: present.length,
        declared: declared,
        root: root,
        agentPresent: !absent,
        skippedBecause: removing
            ? (present.isEmpty
                  ? null
                  : '${present.length} could not be removed from $root')
            : present.length == _skills.length
            ? null
            : absent
            ? 'the agent is not installed in this environment'
            : 'the files were written but are not on disk; something else '
                  'is rewriting $root',
      );
    } on Object catch (error, stack) {
      _log.warning(
        'Could not $verb ${descriptor.id} skills in '
        '${describeEnvironmentId(environmentId)}; leaving $root untouched.',
        error,
        stack,
      );
      return AgentSkillInstallation(
        agentId: descriptor.id,
        environmentId: environmentId,
        installed: 0,
        declared: _skills.length,
        root: root,
        skippedBecause: '$error',
      );
    }
  }

  /// One sweep, published for anything that has to say so out loud.
  Future<AgentSkillInstallationReport> sweep() async {
    final results = await installAll();
    final report = AgentSkillInstallationReport(
      results,
      checkedAt: _ref.read(clockProvider).nowUtc(),
    );
    _ref.read(agentSkillInstallationReportProvider.notifier).set(report);
    _log.info(
      'Agent skills: ${report.complete.length} of ${results.length} stores '
      'carry all ${_skills.length}.',
    );
    return report;
  }

  /// The removal, published the same way, so Settings shows the emptied state
  /// rather than the reading it replaced.
  Future<AgentSkillInstallationReport> sweepRemoval() async {
    final results = await uninstallAll();
    final report = AgentSkillInstallationReport(
      results,
      checkedAt: _ref.read(clockProvider).nowUtc(),
    );
    _ref.read(agentSkillInstallationReportProvider.notifier).set(report);
    _log.info('Agent skills removed from ${results.length} stores.');
    return report;
  }
}

final agentSkillInstallerProvider = Provider<AgentSkillInstaller>(
  (ref) => const AgentSkillInstaller(),
);

final agentSkillInstallationServiceProvider =
    Provider<AgentSkillInstallationService>(
      (ref) => AgentSkillInstallationService(ref),
    );
