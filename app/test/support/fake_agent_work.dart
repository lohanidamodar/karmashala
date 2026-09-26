part of 'fake_data_server.dart';

/// The work a [FakeDataServer] does for its agents (slice 2a) — usage, who
/// is signed in, capture and switch, detection and the CLI import — as a
/// test scripts it. Nothing is read from a disk, a keychain or a vendor: a
/// test seeds [usage] and says what each request answers. What a request
/// writes is told to **every** link, the asker's too, the way the server
/// announces agent work.
class FakeAgentWork {
  FakeAgentWork._(this._server);

  final FakeDataServer _server;

  /// Every account's usage as the fake server last "read" it, by account key.
  final usage = <String, AccountUsageState>{};

  /// Puts [state] as the server's reading and tells every client.
  void setUsage(AccountUsageState state) {
    usage[state.accountKey] = state;
    _server._tell(null, [UsageStateChanged(state)]);
  }

  /// What `usage.refresh` of an account answers — by default the state it
  /// has. Counted in [refreshes].
  AccountUsageState Function(String accountKey)? onRefresh;
  final refreshes = <String?>[];

  /// Who each installation (by id) is signed in as, for `accounts.current`.
  final signIns = <String, AgentSignIn>{};

  /// What `accounts.capture` of an installation saves: a Claude or Codex
  /// account with credentials, which the fake stores and tells without them.
  final captures = <String, Object>{};

  /// Each `accounts.switch`, as (installationId, accountId).
  final switches = <(String, String)>[];

  /// A refusal the next account request of an installation gets.
  final accountRefusals = <String, DataRefused>{};

  /// What `agents.detect` answers (the argument is the environment asked,
  /// null for every one).
  AgentDiscoveryReport Function(String? environmentId) onDetect = (_) =>
      const AgentDiscoveryReport.empty();

  /// What `agents.repair` answers.
  AgentPathRepairReport Function(bool full) onRepair = (_) =>
      AgentPathRepairReport(checkedAt: DateTime.utc(2026));

  /// The projects `imports.scan` finds.
  var detected = <DetectedProject>[];

  /// What `imports.forRepositories` answers, by the repositories asked.
  ImportSummary Function(List<String> repositoryIds) onImportFor = (_) =>
      const ImportSummary();

  /// Each `imports.add`'s projects.
  final added = <List<DetectedProject>>[];

  Object? _handle(AgentWorkRequest<Object?> request, List<DataChange> c) =>
      switch (request) {
        UsageCurrent() => [...usage.values],
        UsageRefresh(:final accountKey) => () {
          refreshes.add(accountKey);
          final keys = accountKey == null ? [...usage.keys] : [accountKey];
          return [
            for (final key in keys)
              if (onRefresh?.call(key) ?? usage[key] case final state?)
                () {
                  if (usage[key] == null || !usage[key]!.sameAs(state)) {
                    usage[key] = state;
                    c.add(UsageStateChanged(state));
                  }
                  return state;
                }(),
          ];
        }(),
        AccountsCurrent(:final installationId) => () {
          _refuse(installationId);
          return signIns[installationId] ?? const NoSignIn();
        }(),
        AccountsCapture(:final installationId) => () {
          _refuse(installationId);
          return switch (captures[installationId]) {
            final ClaudeAccount a => _server._saveClaude(a, c).id,
            final CodexAccount a => _server._saveCodex(a, c).id,
            _ => throw DataRefused.invalid('nothing is signed in there'),
          };
        }(),
        AccountsSwitch(:final installationId, :final accountId) => () {
          _refuse(installationId);
          switches.add((installationId, accountId));
          return const DataAck();
        }(),
        AgentsDetect(:final environmentId) => onDetect(environmentId),
        AgentsRepair(:final full) => onRepair(full),
        AgentsRefreshVersions() => const <AgentVersionChange>[],
        AgentsDiscoverUnprobed() => const <AgentInstallation>[],
        ImportsScan() => detected,
        ImportsAdd(:final projects) => () {
          added.add(projects);
          return ImportSummary(projects: projects.length);
        }(),
        ImportsForRepositories(:final repositoryIds) => onImportFor(
          repositoryIds,
        ),
      };

  void _refuse(String installationId) {
    final refusal = accountRefusals.remove(installationId);
    if (refusal != null) throw refusal;
  }
}
