import 'dart:async';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/application/checkout_picker.dart';
import 'package:karmashala/src/features/explorer/application/session_diff_stat.dart';
import 'package:karmashala/src/features/follow_ups/application/follow_up_inbox.dart';
import 'package:karmashala/src/features/notifications/application/attention_inbox.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_actions.dart';
import 'package:karmashala/src/features/sessions/application/session_resume_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_session/session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// **What one narrow fact costs the app.**
///
/// `sessionsRevisionProvider` is one global counter with sixteen bump sites and
/// twenty-eight watchers, and several of those watchers answer with a full
/// synchronous `SELECT * FROM sessions`. `package:sqlite3` is synchronous, so
/// that scan runs on the UI isolate and inside the frame. The consequence is
/// that renaming *one* session — including the CLI store sweep's title sync,
/// which fires on a timer — costs a table scan per scanning watcher, and the
/// bill grows with every session the user has ever opened.
///
/// The claim these tests pin is the one the owner cares about: **a change to
/// one session costs a number of database reads that does not grow with the
/// number of sessions**, and a watcher whose concern did not change does not
/// read at all.
///
/// Counted, not timed, for the reason `attention_inbox_cost_test.dart` and
/// `layout_write_cost_test.dart` both give: a wall-clock assertion over a
/// few milliseconds fails whenever the machine is busy, and the unit that
/// actually matters here — reads of the session tables — is countable directly.
///
/// The second half of the file is the guard against a false green. A cost test
/// that passes because nothing updates any more is worse than the cost it
/// removed, so every narrowed watcher is also asserted to still update when its
/// concern genuinely moves, and a coarse `bump()` — which every unmigrated
/// caller and every existing test still makes — is asserted to still wake all
/// of them.
void main() {
  /// The three points the curve is read at. One session is the "did we make the
  /// small case worse" control; a hundred is the scale the owner's workspace
  /// reaches.
  const scale = [1, 10, 100];

  /// A workspace of [count] sessions in one project, all but the first running.
  ///
  /// `s0` is the one that ended badly, so exactly one follow-up exists and the
  /// inbox has a label to keep up to date.
  _CountingDatabase seed(int count) {
    final db = _CountingDatabase();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    for (var i = 0; i < count; i++) {
      SessionDao(db).insert(
        session(
          id: 's$i',
          title: 'Session $i',
          status: i == 0 ? SessionStatus.failed : SessionStatus.running,
        ),
      );
    }
    return db;
  }

  ProviderContainer mount(_CountingDatabase db, {FakeCommandRunner? git}) {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        // The status pipeline is not the subject here; the row is.
        agentSessionStatusProvider.overrideWith(
          (ref, id) => const Stream<AgentStatusReport>.empty(),
        ),
        if (git != null)
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(fallback: git),
          ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// Everything the app has watching the session list on an ordinary screen,
  /// subscribed the way the widgets that own them subscribe.
  void listenToEverything(ProviderContainer container, int count) {
    container.read(selectedRepositoryIdProvider.notifier).select('r1');
    container.listen(attentionInboxProvider, (_, _) {});
    container.listen(sessionProjectIdsProvider, (_, _) {});
    container.listen(projectSummaryProvider('p1'), (_, _) {});
    container.listen(openFollowUpsProvider, (_, _) {});
    container.listen(sessionsForSelectedRepositoryProvider, (_, _) {});
    container.listen(importedSessionsForSelectedRepositoryProvider, (_, _) {});
    // One per drawn row: the Explorer builds a card per session.
    for (var i = 0; i < count; i++) {
      container.listen(sessionWhereaboutsProvider('s$i'), (_, _) {});
    }
  }

  group('renaming one session', () {
    /// Filled by the cases below so the *shape* can be asserted across them
    /// rather than inside any one of them.
    final reads = <int, int>{};

    for (final count in scale) {
      test('at $count sessions it costs the same handful of reads', () async {
        final db = seed(count);
        addTearDown(db.close);
        final container = mount(db);
        listenToEverything(container, count);
        await container.pump();

        db.reset();
        unawaited(container.read(sessionActionsProvider).renameNative('s0', 'Renamed'));
        await container.pump();

        reads[count] = db.sessionReads;
        // ignore: avoid_print
        print(
          'SESSION-RENAME-COST sessions=$count '
          'sessionReads=${db.sessionReads} rowsScanned=${db.rowsScanned} '
          'allQueries=${db.queries}',
        );
        expect(
          db.tableScans,
          0,
          reason:
              'nothing may answer a one-row rename with an unfiltered '
              '`SELECT * FROM sessions`: ${db.reads}',
        );
      });
    }

    test('costs the same at a hundred sessions as at one', () {
      expect(reads.keys, containsAll(scale));
      expect(
        reads.values.toSet(),
        hasLength(1),
        reason: 'reads must not grow with the session count: $reads',
      );
    });
  });

  group('what a rename does not wake', () {
    /// The one session row a rename reads **itself**: `renameNative` asks which
    /// CLI conversation the row is backed by before telling that CLI the new
    /// name. An indexed by-id read, made once, by the action — these cases are
    /// about *listeners*, so they are counted against it rather than zero, and
    /// a listener that woke would still push the number past it.
    const renamedRowLookup = 1;

    late _CountingDatabase db;
    late ProviderContainer container;

    setUp(() async {
      db = seed(10);
      container = mount(db);
      container.read(selectedRepositoryIdProvider.notifier).select('r1');
    });
    tearDown(() => db.close());

    /// Subscribes, then renames, and reports what the database was asked.
    ///
    /// Reads are attributed by SQL rather than counted in total because some of
    /// these providers legitimately pull others in behind them —
    /// [projectSummaryProvider] mounts the attention inbox, and the inbox is
    /// *meant* to relabel a renamed session.
    Future<void> renameAfter(void Function() subscribe) async {
      subscribe();
      await container.pump();
      db.reset();
      unawaited(container.read(sessionActionsProvider).renameNative('s0', 'Renamed'));
      await container.pump();
    }

    test('the project placement map — a title is not a placement', () async {
      await renameAfter(
        () => container.listen(sessionProjectIdsProvider, (_, _) {}),
      );
      expect(db.sessionReads, renamedRowLookup, reason: '${db.reads}');
    });

    test('the project summary — it counts rows, it does not name them', () async {
      await renameAfter(
        () => container.listen(projectSummaryProvider('p1'), (_, _) {}),
      );
      expect(
        db.reads.where((sql) => sql.contains('WHERE repository_id = ?')),
        isEmpty,
        reason: 'a header counts sessions; a rename changes no count',
      );
      expect(db.tableScans, 0, reason: '${db.reads}');
    });

    test('another session whereabouts', () async {
      await renameAfter(
        () => container.listen(sessionWhereaboutsProvider('s5'), (_, _) {}),
      );
      expect(db.sessionReads, renamedRowLookup, reason: '${db.reads}');
    });
  });

  group('what a rename must still wake', () {
    late _CountingDatabase db;
    late ProviderContainer container;

    setUp(() async {
      db = seed(10);
      container = mount(db);
      container.read(selectedRepositoryIdProvider.notifier).select('r1');
      container.listen(attentionInboxProvider, (_, _) {});
    });
    tearDown(() => db.close());

    test('the session list shows the new title', () async {
      container.listen(sessionsForSelectedRepositoryProvider, (_, _) {});
      await container.pump();

      unawaited(container.read(sessionActionsProvider).renameNative('s0', 'Renamed'));
      await container.pump();

      expect(
        container
            .read(sessionsForSelectedRepositoryProvider)
            .firstWhere((s) => s.id == 's0')
            .title,
        'Renamed',
      );
    });

    test('the follow-up inbox relabels the session it is about', () async {
      container.listen(openFollowUpsProvider, (_, _) {});
      await container.pump();
      expect(container.read(openFollowUpsProvider).single.label, 'Session 0');

      unawaited(container.read(sessionActionsProvider).renameNative('s0', 'Renamed'));
      await container.pump();

      expect(container.read(openFollowUpsProvider).single.label, 'Renamed');
    });

    test('the renamed session own row provider', () async {
      container.listen(sessionWhereaboutsProvider('s0'), (_, _) {});
      await container.pump();
      db.reset();

      unawaited(container.read(sessionActionsProvider).renameNative('s0', 'Renamed'));
      await container.pump();

      expect(
        db.sessionReads,
        greaterThan(0),
        reason: 'the row that changed must be re-read',
      );
    });
  });

  group('the coarse signal still works', () {
    test('a plain bump wakes every narrowed watcher', () async {
      final db = seed(10);
      addTearDown(db.close);
      final container = mount(db);
      listenToEverything(container, 10);
      await container.pump();

      // A session appears behind the app's back — exactly what an unmigrated
      // bump site says when it says nothing more specific.
      SessionDao(db).insert(session(id: 'sNew', title: 'Arrived'));
      db.reset();
      container.read(sessionsRevisionProvider.notifier).bump();
      await container.pump();

      expect(
        container.read(sessionProjectIdsProvider).containsKey('sNew'),
        isTrue,
        reason: 'the placement map must not miss a coarse bump',
      );
      expect(container.read(projectSummaryProvider('p1')).sessions, 11);
      expect(
        container.read(sessionsForSelectedRepositoryProvider).length,
        11,
      );
      expect(
        db.sessionReads,
        greaterThan(3),
        reason: 'a coarse bump is meant to re-read everything: ${db.reads}',
      );
    });

    test('a per-session watcher wakes on a coarse bump too', () async {
      final db = seed(10);
      addTearDown(db.close);
      final container = mount(db);
      container.listen(sessionWhereaboutsProvider('s5'), (_, _) {});
      await container.pump();

      db.reset();
      container.read(sessionsRevisionProvider.notifier).bump();
      await container.pump();

      expect(
        db.sessionReads,
        greaterThan(0),
        reason:
            'a bump that names no session must be taken to mean all of them, '
            'or a migrated watcher silently stops updating',
      );
    });
  });

  group('membership and status still travel', () {
    late _CountingDatabase db;
    late ProviderContainer container;

    setUp(() async {
      db = seed(10);
      container = mount(db);
      container.read(selectedRepositoryIdProvider.notifier).select('r1');
      container.listen(attentionInboxProvider, (_, _) {});
      container.listen(sessionProjectIdsProvider, (_, _) {});
      container.listen(projectSummaryProvider('p1'), (_, _) {});
      container.listen(sessionsForSelectedRepositoryProvider, (_, _) {});
      await container.pump();
    });
    tearDown(() => db.close());

    test('a deleted session leaves every list', () async {
      await container
          .read(sessionActionsProvider)
          .deleteNative('s3', deleteFromCli: false);
      await container.pump();

      expect(container.read(sessionProjectIdsProvider).containsKey('s3'), isFalse);
      expect(container.read(projectSummaryProvider('p1')).sessions, 9);
      expect(
        container.read(sessionsForSelectedRepositoryProvider).map((s) => s.id),
        isNot(contains('s3')),
      );
    });

    test('a stopped session changes the running count', () async {
      final before = container.read(projectSummaryProvider('p1')).running;
      SessionDao(db).updateStatus('s4', SessionStatus.completed);
      container.read(sessionsRevisionProvider.notifier).bump();
      await container.pump();

      expect(container.read(projectSummaryProvider('p1')).running, before - 1);
    });
  });

  group('the git a rename used to spawn', () {
    test('the checkout picker no longer asks git anything', () async {
      final db = seed(10);
      addTearDown(db.close);
      final git = FakeCommandRunner();
      final container = mount(db, git: git);
      container.read(selectedRepositoryIdProvider.notifier).select('r1');
      container.listen(selectedCheckoutProvider, (_, _) {});
      container.listen(projectCheckoutsProvider, (_, _) {});
      container.listen(selectedCheckoutWorktreesProvider, (_, _) {});
      await container.pump();

      git.requests.clear();
      unawaited(container.read(sessionActionsProvider).renameNative('s0', 'Renamed'));
      await container.pump();

      // ignore: avoid_print
      print('SESSION-RENAME-GIT processes=${git.requests.length}');
      expect(
        git.requests,
        isEmpty,
        reason:
            'renaming a session says nothing about any working tree, so it '
            'must not start a `git worktree list`',
      );
    });
  });
}

/// An [AppDatabase] that records every SELECT, so a change can be priced in the
/// unit that matters: reads of the session tables.
class _CountingDatabase extends AppDatabase {
  _CountingDatabase() : super(sqlite3.openInMemory());

  final List<String> reads = [];
  int rowsScanned = 0;

  void reset() {
    reads.clear();
    rowsScanned = 0;
  }

  int get queries => reads.length;

  static final _sessionTable = RegExp(r'FROM\s+(imported_)?sessions\b');

  /// Reads with no `WHERE` against the two session tables — the full table
  /// scans this whole exercise exists to stop paying for a one-row change.
  static final _unfiltered = RegExp(
    r'FROM\s+sessions\s+ORDER\s+BY'
    r'|FROM\s+imported_sessions\s+WHERE\s+NOT\s+EXISTS',
  );

  /// Reads against the two tables that hold sessions.
  int get sessionReads => reads.where(_sessionTable.hasMatch).length;

  int get tableScans => reads.where(_unfiltered.hasMatch).length;

  @override
  List<Map<String, Object?>> query(
    String sql, [
    List<Object?> params = const [],
  ]) {
    reads.add(sql);
    final rows = super.query(sql, params);
    if (_sessionTable.hasMatch(sql)) rowsScanned += rows.length;
    return rows;
  }
}
