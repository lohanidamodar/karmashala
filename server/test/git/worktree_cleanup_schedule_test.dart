import 'dart:async';
import 'dart:convert';

import 'package:agent_cli/process.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/cleanup.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_host/src/data/data_service.dart';
import 'package:karmashala_host/src/git/worktree_cleanup.dart';
import 'package:karmashala_host/src/git/worktree_cleanup_service.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

class _Clock implements Clock {
  _Clock(this.now);
  DateTime now;
  @override
  DateTime nowUtc() => now;
}

/// Worktree cleanup kept by the server: the setting a client wrote, when the
/// schedule sweeps, and the log and last sweep only the server writes.
void main() {
  final start = DateTime.utc(2026, 9, 27, 12);
  late AppDatabase db;
  late DataService data;
  late DataSession client;
  late List<DataChanges> told;
  late DateTime now;
  late WorktreeCleanup cleanup;
  late Completer<void>? hold;
  late int sweeps;

  const on = WorktreeCleanupSettings(enabled: true);

  WorktreeCleanupService service() => WorktreeCleanupService(
    projects: () => [
      Project(
        id: 'p1',
        name: 'Demo',
        root: const EnvironmentPath(environmentId: 'local', path: '/src'),
        createdAt: start,
      ),
    ],
    repositoriesOf: (_) => [
      Repository(
        id: 'r1',
        projectId: 'p1',
        name: 'app',
        path: const EnvironmentPath(environmentId: 'local', path: '/src/app'),
        createdAt: start,
      ),
    ],
    presenceOf: (_) async {
      sweeps++;
      await hold?.future;
      // Nothing to look at: the schedule is what is tested here.
      return GitPresence.notARepository;
    },
    familyKeyOf: (_) async => null,
    environmentKind: (_) => EnvironmentKind.localPosix,
    gitFor: (_) => throw StateError('no git here'),
    removeIfClean: (_, _) async {},
    sessions: () => const [],
    isLive: (_) => false,
    liveTerminalDirectories: () => const [],
    lastEventAt: (_) async => null,
    createdAt: (_) => null,
    clock: _Clock(start),
  );

  WorktreeCleanup build({bool onItsOwn = false}) => WorktreeCleanup(
    data: data,
    service: service(),
    clock: () => now,
    onItsOwn: onItsOwn,
  );

  void setSettings(WorktreeCleanupSettings settings) => client.handle(
    PreferenceSet(WorktreeCleanupKeys.settings, jsonEncode(settings.toJson())),
  );

  setUp(() {
    db = AppDatabase.memory();
    data = DataService(db, clock: () => now);
    told = [];
    client = data.open(told.add);
    client.handle(const DataSubscribe());
    now = start;
    hold = null;
    sweeps = 0;
    cleanup = build();
  });

  tearDown(() {
    cleanup.stop();
    client.close();
    data.conversations.close();
    db.close();
  });

  test('the setting is the preference a client wrote; unset is off', () {
    expect(cleanup.settings.enabled, isFalse);
    expect(cleanup.nextDue(), isNull);
    setSettings(on);
    expect(cleanup.settings.enabled, isTrue);
  });

  test('due no sooner than the settle after start, the settle after a '
      'change, and the interval after the last sweep', () async {
    setSettings(on);
    expect(cleanup.nextDue(), start.add(kWorktreeCleanupSettleAfterLaunch));

    final changed = start.add(const Duration(hours: 1));
    setSettings(on.copyWith(changedAt: changed));
    expect(cleanup.nextDue(), changed.add(kWorktreeCleanupSettleAfterChange));

    now = start.add(const Duration(hours: 2));
    await cleanup.sweep(automatic: false);
    expect(cleanup.nextDue(), now.add(kWorktreeCleanupInterval));
  });

  test('a sweep records its last sweep in the reserved keys and tells every '
      'client', () async {
    setSettings(on);
    told.clear();
    final report = await cleanup.sweep(automatic: false);

    expect(report.dryRun, isFalse);
    final last = cleanup.log.lastSweep!;
    expect(last.automatic, isFalse);
    expect(last.finishedAt, isNotNull);
    expect(data.serverValue(WorktreeCleanupKeys.lastSweep), isNotNull);
    final changes = [for (final batch in told) ...batch.changes];
    expect(
      changes.whereType<WorktreeCleanupChanged>().single.log.lastSweep,
      isNotNull,
    );
    // A client cannot write the server's record.
    expect(
      () => client.handle(PreferenceSet(WorktreeCleanupKeys.log, '[]')),
      throwsA(isA<DataRefused>()),
    );
  });

  test('the log keeps what a removal attempt said, newest first', () {
    WorktreeCleanupLogEntry entry(String path) => WorktreeCleanupLogEntry(
      at: start,
      projectName: 'Demo',
      worktreePath: path,
      environmentId: 'local',
      rules: const [WorktreeCleanupRule.merged],
      removed: true,
    );
    cleanup.record(entry('/a'));
    cleanup.record(entry('/b'));
    expect([for (final e in cleanup.log.entries) e.worktreePath], ['/b', '/a']);
    expect(cleanup.log.entries.first.rules, [WorktreeCleanupRule.merged]);
  });

  test('a second sweep while one runs joins it', () async {
    setSettings(on);
    hold = Completer<void>();
    final first = cleanup.sweep(automatic: false);
    final second = cleanup.sweep(automatic: true);
    expect(cleanup.isSweeping, isTrue);
    hold!.complete();
    expect(identical(await first, await second), isTrue);
    expect(sweeps, 1);
  });

  test('on its own, a due sweep runs with no client asking', () async {
    cleanup.stop();
    setSettings(on);
    now = start.add(const Duration(hours: 1));
    cleanup = build(onItsOwn: true)..start();
    // Built at `now`, so the launch settle is ahead: nothing yet.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(sweeps, 0);
    cleanup.stop();

    // Its own start long past, the setting on: it sweeps at once.
    final early = WorktreeCleanup(
      data: data,
      service: service(),
      clock: () => now,
      onItsOwn: true,
    );
    now = now.add(const Duration(hours: 1));
    early.start();
    for (var i = 0; i < 50 && early.log.lastSweep?.finishedAt == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    early.stop();
    expect(early.log.lastSweep?.automatic, isTrue);
  });

  test('not on its own, a due sweep waits to be asked', () async {
    cleanup.stop();
    setSettings(on);
    cleanup = build()..start();
    now = now.add(const Duration(hours: 1));
    setSettings(on.copyWith(rules: const WorktreeCleanupRules(merged: false)));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(sweeps, 0);
    expect(cleanup.log.lastSweep, isNull);
  });
}
