import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/explorer/application/unresumable_sessions.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/domain/session_status.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' hide Session;

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/permission_fixtures.dart';
import '../terminal/fake_instance.dart';
import '../../support/temp_directory.dart';

/// **What the review costs, counted — never timed.**
///
/// The house rule, and for the reason every other `*_cost_test.dart` here
/// gives: wall-clock over a few milliseconds fails whenever the machine is
/// busy, and the units that matter are countable directly.
///
/// It is counted here because of what the owner profiled on 2026-09-04: the
/// Explorer's **per-row** git probes — three to five subprocesses each, every
/// one crossing the 9p boundary into WSL — made the UI lag for a long time
/// after launch. A housekeeping feature that answered "is this conversation
/// still there?" by asking per row would be that storm again in a new place,
/// and the single-row `conversationPresenceProvider` is exactly that shape:
/// Codex's answer walks its whole `sessions/` tree, so N rows would be N walks.
///
/// So three counts, taken at 1, 10 and 120 rows:
///
/// 1. **Store locates** — one per reading, or zero when nothing is worth
///    asking about.
/// 2. **Store listings** — one per (store, agent with a readable format), and
///    never one per row.
/// 3. **SQL statements** — whatever one reading costs, *the same* number at
///    120 rows as at one. The absolute figure is not the claim (it includes
///    the terminal controller's own layout read, which the screening does not
///    own); flatness is. A `getById` per row was the first version of this and
///    is what these numbers forbid.
///
/// The 1-row reading is the baseline the other two are compared against, so a
/// per-row statement anywhere in the path fails this whether or not anybody
/// remembered to update a constant.

const _claudeish = AgentDescriptor(
  id: 'claudeish',
  displayName: 'Claudeish',
  binaries: AgentBinaries(windows: ['claudeish'], posix: ['claudeish']),
  launch: AgentLaunchSpec(
    permission: testPermissionSupport,
    sessionIdAssignment: AgentSessionIdAssignment.flag('--session-id'),
  ),
  store: AgentStoreSpec(
    homeDirectoryName: '.claude',
    format: AgentStoreFormat.claudeJsonl,
  ),
);

/// What one reading cost. A record rather than four locals, so the comparison
/// below reads as one claim about two readings.
class _Cost {
  const _Cost({
    required this.locates,
    required this.listings,
    required this.singleProbes,
    required this.statements,
  });

  final int locates;
  final int listings;
  final int singleProbes;
  final int statements;
}

class _StaticSettings extends SettingsController {
  @override
  Settings build() => const Settings();
}

/// Counts the SQL the reading issues. `package:sqlite3` is synchronous, so each
/// statement runs on the UI isolate inside the frame.
class _CountingDatabase extends AppDatabase {
  _CountingDatabase() : super(sqlite3.openInMemory());

  int statements = 0;

  void reset() => statements = 0;

  @override
  List<Map<String, Object?>> query(
    String sql, [
    List<Object?> params = const [],
  ]) {
    statements++;
    return super.query(sql, params);
  }
}

class _CountingLocator extends CliStoreLocator {
  _CountingLocator(this.stores) : super(runnerFor: ((_) => FakeCommandRunner()));

  final List<CliStore> stores;
  int calls = 0;

  @override
  Future<List<CliStore>> locate(
    List<ExecutionEnvironment> environments,
  ) async {
    calls++;
    return stores;
  }
}

/// Counts the listings, which is the unit that would grow per row if the
/// single-row probe were used instead of the sweep.
class _CountingIndex extends ConversationStoreIndex {
  const _CountingIndex(this._counts);

  final List<String> _counts;

  int get listings => _counts.length;

  @override
  Future<Set<String>?> idsIn({
    required String storeHome,
    required AgentStoreFormat format,
  }) {
    _counts.add('$storeHome/$format');
    return const ConversationStoreIndex().idsIn(
      storeHome: storeHome,
      format: format,
    );
  }

  @override
  Future<ConversationPresence> presenceOf({
    required String storeHome,
    required AgentStoreFormat format,
    required String conversationId,
  }) {
    _counts.add('single/$storeHome');
    return const ConversationStoreIndex().presenceOf(
      storeHome: storeHome,
      format: format,
      conversationId: conversationId,
    );
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('karmashala_ucost_'));
  tearDown(() => removeTempDirectory(tmp));

  /// A store that exists and reads to the end, holding nothing — so every row
  /// below is genuinely `absent` and the reading has the most work to do.
  void emptyStore(String name) => Directory(
    p.join(tmp.path, name, 'projects'),
  ).createSync(recursive: true);

  /// One reading over [rows] dead sessions, returning what it cost.
  Future<_Cost> readingOver(int rows) async {
      final db = _CountingDatabase();
      addTearDown(db.close);
      ExecutionEnvironmentDao(db).upsert(windowsEnv());
      ExecutionEnvironmentDao(db).upsert(wslEnv());
      ProjectDao(db).insert(project());
      RepositoryDao(db).insert(repository());
      AgentInstallationDao(db).insert(agentInstallation(agentId: 'claudeish'));
      emptyStore('.claude');
      emptyStore('.wsl-claude');

      final locator = _CountingLocator([
        CliStore(
          environmentId: 'windows',
          homesByAgentId: {'claudeish': p.join(tmp.path, '.claude')},
        ),
        CliStore(
          environmentId: 'wsl:Ubuntu',
          homesByAgentId: {'claudeish': p.join(tmp.path, '.wsl-claude')},
        ),
      ]);
      final listings = <String>[];
      final index = _CountingIndex(listings);

      final container = ProviderContainer(
        overrides: [
          ...fakeTerminalOverrides(database: db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(),
          ),
          idGeneratorProvider.overrideWithValue(SequentialIdGenerator('s-')),
          agentRegistryProvider.overrideWithValue(
            const AgentRegistry([_claudeish]),
          ),
          settingsControllerProvider.overrideWith(_StaticSettings.new),
          agentSessionStatusProvider.overrideWith(
            (ref, id) => const Stream<AgentStatusReport>.empty(),
          ),
          cliStoreLocatorProvider.overrideWithValue(locator),
          conversationStoreIndexProvider.overrideWithValue(index),
        ],
      );
      addTearDown(container.dispose);

      final dao = container.read(sessionDaoProvider);
      for (var i = 0; i < rows; i++) {
        dao.insert(
          session(id: 'dead-$i', title: 'Session $i').copyWith(
            externalSessionId: 'dead-$i',
            status: SessionStatus.running,
            createdAt: testTime.subtract(const Duration(hours: 2)),
          ),
        );
      }
      db.reset();

      await container.read(unresumableSessionsProvider.notifier).refresh();

      expect(
        container.read(unresumableSessionsProvider).removable,
        hasLength(rows),
        reason: 'every row must actually be judged, or the counts are '
            'measuring a reading that did nothing',
      );
      return _Cost(
        locates: locator.calls,
        listings: index.listings,
        singleProbes: listings.where((l) => l.startsWith('single/')).length,
        statements: db.statements,
      );
  }

  test('one reading costs the same at 1, 10 and 120 dead rows', () async {
    final one = await readingOver(1);
    final ten = await readingOver(10);
    final many = await readingOver(120);

    // One reading is one locate and one listing per store, at every size.
    for (final cost in [one, ten, many]) {
      expect(cost.locates, 1, reason: 'one reading is one locate');
      expect(
        cost.listings,
        2,
        reason: 'one listing per store, not one per row — the whole point of '
            'the sweep',
      );
      expect(
        cost.singleProbes,
        0,
        reason: 'the single-row probe is the per-row storm this replaces',
      );
    }

    // And the SQL is flat: the baseline, not a constant somebody has to keep
    // up to date.
    expect(
      ten.statements,
      one.statements,
      reason: 'ten rows cost ${ten.statements} statements against '
          '${one.statements} for one',
    );
    expect(
      many.statements,
      one.statements,
      reason: '120 rows cost ${many.statements} statements against '
          '${one.statements} for one — something in the path reads per row',
    );
    // A sanity floor, so a reading that somehow issued no SQL at all cannot
    // pass by being equally free at every size.
    expect(one.statements, greaterThan(0));
    expect(one.statements, lessThan(12));
  });

  test('screening a workspace with no candidate touches no store at all', () async {
    // 120 rows, none of which ever made a promise: the free half answers on
    // its own and the disk is never opened.
    final db = _CountingDatabase();
    addTearDown(db.close);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation(agentId: 'claudeish'));

    final locator = _CountingLocator([
      CliStore(
        environmentId: 'windows',
        homesByAgentId: {'claudeish': p.join(tmp.path, '.claude')},
      ),
    ]);
    final listings = <String>[];
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(),
        ),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('s-')),
        agentRegistryProvider.overrideWithValue(
          const AgentRegistry([_claudeish]),
        ),
        settingsControllerProvider.overrideWith(_StaticSettings.new),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => const Stream<AgentStatusReport>.empty(),
        ),
        cliStoreLocatorProvider.overrideWithValue(locator),
        conversationStoreIndexProvider.overrideWithValue(
          _CountingIndex(listings),
        ),
      ],
    );
    addTearDown(container.dispose);

    final dao = container.read(sessionDaoProvider);
    for (var i = 0; i < 120; i++) {
      // An id the CLI chose for itself, which is not a promise of ours.
      dao.insert(
        session(id: 'row-$i').copyWith(
          externalSessionId: 'cli-chose-$i',
          status: SessionStatus.running,
          createdAt: testTime.subtract(const Duration(hours: 2)),
        ),
      );
    }
    db.reset();

    await container.read(unresumableSessionsProvider.notifier).refresh();

    expect(locator.calls, 0);
    expect(listings, isEmpty);
    // Fewer than a reading that swept, because the sweep's own environment
    // read never happened — and in no case per row.
    expect(db.statements, lessThan(12));
    expect(container.read(unresumableSessionsProvider).hasRun, isTrue);
  });
}
