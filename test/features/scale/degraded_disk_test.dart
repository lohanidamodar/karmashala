import 'dart:async';
import 'dart:io';

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/terminal/application/scrollback_autosave.dart';
import 'package:karmashala/src/features/terminal/data/terminal_workspace_dao.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:sqlite3/sqlite3.dart';

import 'scale_harness.dart';

/// **The degraded-disk gate.** One of the four benchmark gates
/// `docs/BACKLOG.md` carried as unbuilt.
///
/// Two failures matter, and they are different failures. A **slow** write
/// blocks the UI isolate, because `package:sqlite3` is synchronous and every
/// save runs on it. A **failing** write throws in the middle of a transaction
/// that was half-way through replacing the user's workspace. Against both, the
/// app has to hold three lines:
///
/// 1. **it must not lose the workspace** — not a tab, not a pane's scrollback,
///    and not silently by *skipping* a write it now believes it made;
/// 2. **it must not hang the UI** — a slow disk costs a bounded slice of
///    main-isolate time per tick, not a slice proportional to how much is open;
/// 3. **it must report rather than swallow** — a save that could not happen
///    goes in the log, at a level someone reads.
///
/// Two pieces of the app exist precisely for this and neither was exercised
/// under a degraded disk before this file:
///
/// * `TerminalWorkspaceDao.saveWorkspace`'s **rollback guard** — the record of
///   what has been written is adopted *after* the transaction commits, "because
///   a record claiming rows that were rolled back is the one way this dao could
///   skip a write it owed". A failed save that adopted its record would leave
///   the store holding old text and the dao convinced it was new: silent,
///   permanent loss of everything that pane printed.
/// * the **empty-workspace refusal** in `_persist` — a save that would replace
///   a non-empty stored workspace with an empty one, with nothing the user did
///   to account for it, is refused. A disk that fails the *restore* read is the
///   cleanest way there is to reach that state, and it is the state that
///   destroys a workspace on the way out.
///
/// Counted, not timed, like every other gate here — with one deliberate
/// exception, marked at the line: the slow-disk case asserts *how many panes*
/// one autosave tick writes when each write blocks for far longer than the
/// tick's budget. That is a count, and a busier machine can only make the
/// writes slower, which is the direction the assertion already holds in.
void main() {
  /// Records the app's own log, so "it must report" can be asserted rather
  /// than assumed.
  late List<LogRecord> logged;
  late StreamSubscription<LogRecord> logging;

  setUp(() {
    logged = [];
    Logger.root.level = Level.INFO;
    logging = Logger.root.onRecord.listen(logged.add);
  });

  tearDown(() => logging.cancel());

  Iterable<LogRecord> atLeast(Level level) =>
      logged.where((record) => record.level >= level);

  group('a disk that has stopped accepting writes', () {
    test('rolls the whole save back and loses nothing', () {
      final disk = DegradedDatabase();
      final workspace = ScaleWorkspace(database: disk);
      addTearDown(workspace.dispose);
      final panes = workspace.openPanes(2, linesPerPane: 40);
      workspace.settle();
      final storedBefore = [
        for (final pane in panes) workspace.storedScrollback(pane),
      ];
      expect(storedBefore, everyElement(isNotEmpty));

      for (final pane in panes) {
        workspace.controller.instanceFor(pane)!.terminal.write(
          'work the user has not finished\r\n',
        );
      }
      // The second pane row is the one refused, so the first has already been
      // written inside the transaction when the disk says no — which is the
      // only shape in which a rollback can be wrong.
      disk
        ..failing = 'INSERT INTO terminal_panes'
        ..allowBeforeFailing = 1;
      logged.clear();

      workspace.controller.persistWorkspace();

      expect(disk.refusals, 1);
      expect(
        [for (final pane in panes) workspace.storedScrollback(pane)],
        storedBefore,
        reason:
            'a save that threw half-way must leave the store exactly as it '
            'found it',
      );
      expect(
        workspace.storedTabRows,
        2,
        reason: 'and it must not take a tab with it',
      );
      expect(
        atLeast(Level.WARNING),
        isNotEmpty,
        reason: 'a save that could not happen must be reported, not swallowed',
      );
    });

    test('and the next save writes everything the failed one owed', () {
      // The rollback guard, stated as the thing the user would notice: the
      // pane whose row was rolled back must not be skipped for ever by a dao
      // that thinks it wrote it.
      final disk = DegradedDatabase();
      final workspace = ScaleWorkspace(database: disk);
      addTearDown(workspace.dispose);
      final panes = workspace.openPanes(2, linesPerPane: 40);
      workspace.settle();

      for (final pane in panes) {
        workspace.controller.instanceFor(pane)!.terminal.write(
          'work the user has not finished\r\n',
        );
      }
      disk
        ..failing = 'INSERT INTO terminal_panes'
        ..allowBeforeFailing = 1;
      workspace.controller.persistWorkspace();

      disk.failing = null;
      workspace.controller.persistWorkspace();

      for (final pane in panes) {
        expect(
          workspace.storedScrollback(pane),
          contains('work the user has not finished'),
          reason: 'pane $pane was written by nobody',
        );
      }
    });

    test('leaves the workspace usable, and restorable', () {
      final disk = DegradedDatabase();
      final workspace = ScaleWorkspace(database: disk);
      addTearDown(workspace.dispose);
      final panes = workspace.openPanes(3, linesPerPane: 40);
      workspace.settle();

      disk.failing = 'INSERT INTO terminal_panes';
      workspace.controller.instanceFor(panes.first)!.terminal.write('more\r\n');
      workspace.controller.persistWorkspace();

      // The app is still an app: nothing threw out of the save, every pane is
      // still live, and the next thing the user does still works.
      expect(workspace.state.tabs, hasLength(3));
      for (final pane in panes) {
        expect(workspace.controller.instanceFor(pane), isNotNull);
      }
      disk.failing = null;
      final added = workspace.openPane();
      expect(workspace.controller.instanceFor(added), isNotNull);
      expect(workspace.state.tabs, hasLength(4));

      // And what is on disk is a workspace, not a fragment of one.
      final restored = TerminalWorkspaceDao(disk).loadWorkspace();
      expect(restored.tabs, hasLength(4));
      expect(
        restored.tabs.every((tab) => tab.panes.isNotEmpty),
        isTrue,
        reason: 'a rolled-back save must not leave a tab with no panes',
      );
    });

    test('does not answer one refusal with a storm of retries', () {
      final disk = DegradedDatabase();
      final workspace = ScaleWorkspace(database: disk);
      addTearDown(workspace.dispose);
      final panes = workspace.openPanes(10, linesPerPane: 40);
      workspace.settle();
      for (final pane in panes) {
        workspace.controller.instanceFor(pane)!.terminal.write('more\r\n');
      }

      disk
        ..failing = 'INSERT INTO terminal_panes'
        ..reset();
      workspace.controller.persistWorkspace();

      // ignore: avoid_print
      print(
        'DEGRADED-DISK refusals=${disk.refusals} '
        'statements=${disk.statements.length}',
      );
      expect(
        disk.refusals,
        1,
        reason: 'a refused save is abandoned, not retried per pane',
      );
    });
  });

  group('a disk that fails the restore read', () {
    test('must not let the quit-time save erase the workspace', () {
      final disk = DegradedDatabase();
      addTearDown(disk.close);

      // A workspace the user has, written by a healthy app.
      final first = ScaleWorkspace(database: disk);
      final panes = first.openPanes(3, linesPerPane: 40);
      first.settle();
      final stored = [for (final pane in panes) first.storedScrollback(pane)];
      first.container.dispose();
      expect(TerminalWorkspaceDao(disk).storedTabCount(), 3);

      // The app restarts on a disk that will not read the workspace back.
      // `_restoreWorkspace` catches, logs, and comes up with nothing — which
      // is exactly the state the refusal exists for, and the state that used
      // to destroy the workspace on the way out.
      disk.failing = 'FROM terminal_tabs ORDER BY ordinal';
      logged.clear();
      final second = ScaleWorkspace(database: disk);
      addTearDown(second.container.dispose);
      expect(second.state.tabs, isEmpty);
      expect(
        atLeast(Level.WARNING),
        isNotEmpty,
        reason: 'a restore that read nothing must say so',
      );

      disk.failing = null;
      logged.clear();
      second.controller.persistWorkspace();

      expect(
        TerminalWorkspaceDao(disk).storedTabCount(),
        3,
        reason: 'the stored workspace must outlive a restore that read nothing',
      );
      expect(
        [for (final pane in panes) second.storedScrollback(pane)],
        stored,
        reason: 'and every pane keeps the text it had',
      );
      expect(
        TerminalWorkspaceDao(disk).loadBackup().tabs,
        isEmpty,
        reason:
            'nothing was written, so there was nothing to take a copy of — a '
            'backup here would mean the refusal came too late',
      );
      expect(
        atLeast(Level.SEVERE),
        isNotEmpty,
        reason:
            'refusing to write is the right call and an abnormal one; it has '
            'to be visible',
      );
    });
  });

  group('a disk that is merely slow', () {
    /// Far longer than [kScrollbackAutosaveBudget], so the budget is the thing
    /// being measured rather than the machine.
    const perWrite = Duration(milliseconds: 25);

    test('costs one autosave tick one pane, not all of them', () {
      final disk = DegradedDatabase();
      final workspace = ScaleWorkspace(database: disk);
      addTearDown(workspace.dispose);
      final panes = workspace.openPanes(6, linesPerPane: 40);
      expect(workspace.controller.hasDirtyScrollback, isTrue);

      disk.writeDelay = perWrite;
      // The one number in this directory taken against a clock, and only
      // because the app's own budget is: each write blocks for 25 ms against
      // an 8 ms tick, so the tick can only ever get through one. A loaded
      // machine makes the writes slower, which is the same answer.
      final written = workspace.controller.saveDirtyScrollback();

      // ignore: avoid_print
      print(
        'DEGRADED-DISK-SLOW perWrite=${perWrite.inMilliseconds}ms '
        'budget=${kScrollbackAutosaveBudget.inMilliseconds}ms '
        'panes=${panes.length} writtenPerTick=${written.length}',
      );
      expect(
        written,
        hasLength(1),
        reason:
            'a slow disk must cost the UI isolate one write per tick, not one '
            'per open pane',
      );
      expect(workspace.controller.hasDirtyScrollback, isTrue);
    });

    test('and the backlog drains rather than being dropped', () {
      final disk = DegradedDatabase();
      final workspace = ScaleWorkspace(database: disk);
      addTearDown(workspace.dispose);
      final panes = workspace.openPanes(6, linesPerPane: 40);
      disk.writeDelay = perWrite;

      var ticks = 0;
      while (workspace.controller.hasDirtyScrollback && ticks < 50) {
        workspace.controller.saveDirtyScrollback();
        ticks++;
      }

      expect(ticks, panes.length, reason: 'one pane per tick, and no more');
      expect(workspace.controller.hasDirtyScrollback, isFalse);
      for (final pane in panes) {
        expect(workspace.storedScrollback(pane), isNotEmpty);
      }
    });

    test('asks the autosave to come back on its catch-up cadence', () {
      // The other half of "must not hang the UI": deferring a write is only
      // acceptable if the deferral is short. A structural save that left text
      // behind asks for the 1 s cadence rather than whatever idle tick was
      // armed.
      final disk = DegradedDatabase();
      final workspace = ScaleWorkspace(database: disk);
      addTearDown(workspace.dispose);
      final panes = workspace.openPanes(3, linesPerPane: 40);
      workspace.settle();
      // A tick with nothing owing re-arms at the idle cadence, so whatever the
      // save below asks for is that save's doing and not a leftover — the
      // autosave declines to bring a catch-up tick that is already armed any
      // closer.
      workspace.schedule.fire();

      disk.writeDelay = perWrite;
      workspace.controller.instanceFor(panes.first)!.terminal.write('more\r\n');
      workspace.schedule.delays.clear();
      workspace.openPane();

      expect(workspace.schedule.delays, contains(kScrollbackAutosaveCatchUp));
    });
  });
}

/// A database that can be made to behave like a disk in trouble: refusing
/// statements, or accepting them slowly.
///
/// Refusals are matched on the SQL itself so a test can name the exact write it
/// wants to fail, and [allowBeforeFailing] lets the failure land *after* other
/// rows in the same transaction have already been written — the only shape in
/// which a rollback can be got wrong.
///
/// `BEGIN`/`COMMIT`/`ROLLBACK` go through `AppDatabase`'s private handle rather
/// than [execute], so a refused statement still rolls back exactly as it would
/// against a real disk that failed one write.
class DegradedDatabase extends AppDatabase {
  DegradedDatabase() : super(sqlite3.openInMemory());

  /// Statements containing this are refused. Null while the disk is healthy.
  Pattern? failing;

  /// How many matching statements to let through before refusing.
  int allowBeforeFailing = 0;

  /// How long every accepted write blocks the calling isolate — which is the
  /// UI isolate, because `package:sqlite3` is synchronous.
  Duration writeDelay = Duration.zero;

  final List<String> statements = [];
  int refusals = 0;
  int _matched = 0;

  void reset() {
    statements.clear();
    refusals = 0;
    _matched = 0;
  }

  bool _refuses(String sql) {
    final pattern = failing;
    if (pattern == null || !sql.contains(pattern)) return false;
    if (_matched++ < allowBeforeFailing) return false;
    refusals++;
    return true;
  }

  @override
  List<Map<String, Object?>> query(
    String sql, [
    List<Object?> params = const [],
  ]) {
    statements.add(sql);
    if (_refuses(sql)) {
      throw const FileSystemException('disk I/O error');
    }
    return super.query(sql, params);
  }

  @override
  void execute(String sql, [List<Object?> params = const []]) {
    statements.add(sql);
    if (_refuses(sql)) {
      throw const FileSystemException('disk I/O error');
    }
    if (writeDelay > Duration.zero) sleep(writeDelay);
    super.execute(sql, params);
  }
}
