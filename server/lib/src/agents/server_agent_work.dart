import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:sqlite3/sqlite3.dart';

import '../data/agent_work.dart';
import '../data/data_service.dart';
import 'server_accounts.dart';
import 'server_detection.dart';
import 'server_imports.dart';
import 'server_usage.dart';

/// Set to `off` in a server's environment, it does agent work only when a
/// client asks: no usage schedule and no start-up check (live tests).
const String kAgentWorkVariable = 'KARMASHALA_AGENT_WORK';

/// Everything the server does for the agents on its machine (slice 2a),
/// built once by `serve` over its data service and answering the clients'
/// `AgentWorkRequest`s: usage ([usage]), accounts ([accounts]), detection
/// ([detection]) and the CLI import ([imports]). Commands run where
/// [runners] reaches: this machine, its WSL distributions, and an SSH box
/// through the server's own connection (`ServerSsh`, slice 3a).
class ServerAgentWork implements AgentWork {
  ServerAgentWork({
    required DataService data,
    CommandRunnerFactory runners = const CommandRunnerFactory(),
    Clock clock = const SystemClock(),
    IdGenerator? ids,
    AgentRegistry registry = AgentRegistry.builtIn,
    Map<String, String> hostEnvironment = const {},
    PathProbe pathProbe = const LocalPathProbe(),
    AgentUsageService Function(CliStoreLocator stores)? usageService,
    ClaudeAuthService? claudeAuth,
    this.onItsOwn = true,
  }) : _data = data {
    final generator = ids ?? RandomIdGenerator();
    CommandRunner runnerFor(ExecutionEnvironment environment) =>
        runners.forEnvironment(environment);
    final stores = CliStoreLocator(
      runnerFor: (id) => runnerFor(
        data.environments.where((e) => e.id == id).firstOrNull ??
            (throw StateError('no environment with id $id')),
      ),
      registry: registry,
      installations: data.installations,
      environment: hostEnvironment,
    );
    usage = ServerUsage(
      data: data,
      service:
          usageService?.call(stores) ??
          AgentUsageService(
            storeLocator: stores,
            clock: clock,
            registry: registry,
          ),
      registry: registry,
      clock: clock,
    );
    accounts = ServerAccounts(
      data: data,
      stores: stores,
      ids: generator,
      clock: clock,
      registry: registry,
      claude: claudeAuth,
    );
    detection = ServerDetection(
      data: data,
      runnerFor: runnerFor,
      ids: generator,
      clock: clock,
      registry: registry,
      pathProbe: pathProbe,
      hostEnvironment: hostEnvironment,
    );
    imports = ServerImports(
      data: data,
      stores: stores,
      readRows: readSqliteRows,
      ids: generator,
      clock: clock,
      registry: registry,
    );
  }

  final DataService _data;

  /// Whether the server reads usage on its schedule and checks its agents at
  /// start by itself; off, it works only when a client asks (tests).
  final bool onItsOwn;

  late final ServerUsage usage;
  late final ServerAccounts accounts;
  late final ServerDetection detection;
  late final ServerImports imports;

  /// Answers the clients' agent work from now on.
  void attach() => _data.agentWork = this;

  /// What the server does on its own once it is up: the usage schedule, and
  /// the check of its agents (a rotted path, agents nobody searched for,
  /// aged versions).
  Future<void> start({void Function(String line)? log}) async {
    if (!onItsOwn) return;
    usage.start();
    await detection.startup(log: log);
  }

  void stop() {
    usage.stop();
    if (identical(_data.agentWork, this)) _data.agentWork = null;
  }

  @override
  List<AccountUsageState> usageStates() => usage.states();

  @override
  Future<Object?> handle(AgentWorkRequest<Object?> request) async =>
      switch (request) {
        UsageCurrent() => usage.states(),
        UsageRefresh(:final accountKey) => await usage.refresh(
          accountKey: accountKey,
        ),
        AccountsCurrent(:final installationId) => await accounts.current(
          installationId,
        ),
        AccountsCapture(:final installationId) => await accounts.capture(
          installationId,
        ),
        AccountsSwitch(:final installationId, :final accountId) =>
          await () async {
            await accounts.switchTo(installationId, accountId);
            return const DataAck();
          }(),
        AgentsDetect(:final environmentId) => await detection.detect(
          environmentId: environmentId,
        ),
        AgentsRepair(:final full) => await detection.repair(full: full),
        AgentsRefreshVersions() => await detection.refreshVersions(),
        AgentsDiscoverUnprobed() => await detection.discoverUnprobed(),
        ImportsScan() => await imports.scan(),
        ImportsAdd(:final projects) => await imports.add(projects),
        ImportsForRepositories(:final repositoryIds) =>
          await imports.forRepositories(repositoryIds),
      };
}

/// The server's [SqliteRowReader]: read-only, `null` on any failure — a busy
/// database is "not recorded", not an error to propagate.
Future<List<Map<String, Object?>>?> readSqliteRows(
  String path,
  String sql,
) async {
  Database? db;
  try {
    db = sqlite3.open(path, mode: OpenMode.readOnly);
    return [
      for (final row in db.select(sql)) {...row},
    ];
  } on Object {
    return null;
  } finally {
    db?.close();
  }
}
