import 'dart:async';

import 'package:karmashala_git/git.dart';
import 'package:karmashala_store/database.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/database/database_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/application/environment_resolver.dart';
import 'package:karmashala_git/repositories.dart';
import '../../workspaces/data/workspace_data.dart';
import '../../sessions/application/session_launcher.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_signals.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../data/worktree_cleanup_store.dart';
import 'changes_providers.dart';
import 'git_providers.dart';
import 'worktree_cleanup_policy.dart';
import 'worktree_cleanup_service.dart';

final worktreeCleanupStoreProvider = Provider<WorktreeCleanupStore>(
  (ref) => WorktreeCleanupStore(ref.watch(appPreferencesProvider)),
);

/// Bumped by every settings change and every sweep, so the page and the
/// scheduler's timer notice without polling.
class WorktreeCleanupRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state = state + 1;
}

final worktreeCleanupRevisionProvider =
    NotifierProvider<WorktreeCleanupRevision, int>(WorktreeCleanupRevision.new);

final worktreeCleanupSettingsProvider = Provider<WorktreeCleanupSettings>((
  ref,
) {
  ref.watch(worktreeCleanupRevisionProvider);
  return ref.watch(worktreeCleanupStoreProvider).settings();
});

final worktreeCleanupLogProvider = Provider<List<WorktreeCleanupLogEntry>>((
  ref,
) {
  ref.watch(worktreeCleanupRevisionProvider);
  return ref.watch(worktreeCleanupStoreProvider).log();
});

final worktreeCleanupLastSweepProvider = Provider<WorktreeCleanupSweepSummary?>(
  (ref) {
    ref.watch(worktreeCleanupRevisionProvider);
    return ref.watch(worktreeCleanupStoreProvider).lastSweep();
  },
);

/// Every collaborator is read inside its callback, so building this runs no
/// git and builds no terminal until a sweep actually asks.
final worktreeCleanupServiceProvider = Provider<WorktreeCleanupService>((ref) {
  AppDatabase db() => ref.read(databaseProvider);
  return WorktreeCleanupService(
    projects: () => ref.read(workspaceDataProvider).projects,
    repositoriesOf: (id) => ref.read(workspaceDataProvider).repositoriesOf(id),
    presenceOf: (path) async {
      final env = ref
          .read(environmentResolverProvider)
          .resolveFor(path)
          .environment;
      if (env == null) return GitPresence.unknown;
      return GitPresenceReader(
        files: ref.read(gitFilesProvider),
        hostPathOf: hostPathMapperFor(env),
      ).read(path.path);
    },
    familyKeyOf: (path) => ref.read(changesServiceProvider).familyKey(path),
    environmentKind: (id) =>
        ref.read(executionEnvironmentDaoProvider).getById(id)?.kind,
    gitFor: (repo) => ref.read(worktreeServiceProvider).gitFor(repo),
    removeIfClean: (repo, worktree) =>
        ref.read(worktreeServiceProvider).removeIfClean(repo, worktree),
    sessions: () => ref.read(sessionsDataProvider).getAll(),
    // A status that claims a run counts even with no pane behind it: "we lost
    // track of it" is not evidence that nothing is working in the directory.
    isLive: (session) =>
        session.status.claimsLive ||
        ref.read(sessionLauncherProvider).livePaneFor(session.id) != null,
    liveTerminalDirectories: () {
      final state = ref.read(terminalSessionsControllerProvider);
      return [
        for (final entry in state.workingDirectories.entries)
          if (entry.value != null && state.livenessOf(entry.key).isLive)
            entry.value!,
      ];
    },
    lastEventAt: (ids) =>
        ref.read(sessionRecordsProvider).lastEventAt(ids.toList()),
    createdAt: (worktree) {
      final rows = db().query(
        'SELECT worktree_path, ran_at FROM worktree_setup_runs '
        'WHERE environment_id = ?;',
        [worktree.environmentId],
      );
      for (final row in rows) {
        if (samePath(row['worktree_path']! as String, worktree.path)) {
          return dateFromIso(row['ran_at']);
        }
      }
      return null;
    },
    clock: ref.watch(clockProvider),
    onRemoved: (entry, sessionIds) {
      ref.read(worktreeCleanupStoreProvider).appendLog(entry);
      if (!entry.removed) return;
      // The same record the archive action leaves: the row and transcript
      // survive, and nothing offers to resume into a directory that is gone.
      for (final id in sessionIds) {
        ref.read(sessionsDataProvider).markArchived(id, entry.at);
        ref
            .read(sessionsRevisionProvider.notifier)
            .changed(SessionChange.archived(id));
      }
    },
  );
});

/// Saves the setting and runs sweeps — the one path both the timer and the
/// Settings buttons take, so two sweeps never overlap.
class WorktreeCleanupController {
  WorktreeCleanupController(this._ref);

  final Ref _ref;

  Future<WorktreeCleanupReport>? _inFlight;

  bool get isSweeping => _inFlight != null;

  WorktreeCleanupSettings get settings =>
      _ref.read(worktreeCleanupStoreProvider).settings();

  void save(WorktreeCleanupSettings settings) {
    _ref
        .read(worktreeCleanupStoreProvider)
        .saveSettings(
          settings.copyWith(changedAt: _ref.read(clockProvider).nowUtc()),
        );
    _ref.read(worktreeCleanupRevisionProvider.notifier).bump();
  }

  /// A dry run: removes nothing, writes nothing.
  Future<WorktreeCleanupReport> preview() =>
      _ref.read(worktreeCleanupServiceProvider).preview(settings);

  /// A real sweep under the current setting, or the one already running.
  Future<WorktreeCleanupReport> sweep({required bool automatic}) {
    final running = _inFlight;
    if (running != null) return running;
    final future = _sweep(automatic);
    _inFlight = future;
    return future.whenComplete(() => _inFlight = null);
  }

  Future<WorktreeCleanupReport> _sweep(bool automatic) async {
    final store = _ref.read(worktreeCleanupStoreProvider);
    final clock = _ref.read(clockProvider);
    final started = clock.nowUtc();
    // Recorded first, so the next due time moves on even if this one throws.
    store.saveLastSweep(
      WorktreeCleanupSweepSummary(startedAt: started, automatic: automatic),
    );
    try {
      final report = await _ref
          .read(worktreeCleanupServiceProvider)
          .sweep(settings, automatic: automatic);
      store.saveLastSweep(
        WorktreeCleanupSweepSummary(
          startedAt: started,
          finishedAt: clock.nowUtc(),
          automatic: automatic,
          removed: report.withOutcome(WorktreeCleanupOutcome.removed).length,
          kept: report.withOutcome(WorktreeCleanupOutcome.kept).length,
          failed: report.withOutcome(WorktreeCleanupOutcome.failed).length,
        ),
      );
      return report;
    } catch (error) {
      store.saveLastSweep(
        WorktreeCleanupSweepSummary(
          startedAt: started,
          finishedAt: clock.nowUtc(),
          automatic: automatic,
          error: '$error',
        ),
      );
      rethrow;
    } finally {
      if (_ref.mounted) {
        _ref.read(worktreeCleanupRevisionProvider.notifier).bump();
      }
    }
  }

  /// When the automatic sweep is next due, or null when nothing is turned on.
  /// Never earlier than [kWorktreeCleanupSettleAfterChange] after a settings
  /// change or [kWorktreeCleanupSettleAfterLaunch] after [availableSince].
  DateTime? nextDue({required DateTime availableSince}) {
    // No in-flight check: a sweep records its start first, which already
    // moves the next due time [kWorktreeCleanupInterval] on.
    final store = _ref.read(worktreeCleanupStoreProvider);
    final settings = store.settings();
    if (!settings.anyEnabled) return null;
    final floors = [
      availableSince.add(kWorktreeCleanupSettleAfterLaunch),
      if (settings.changedAt != null)
        settings.changedAt!.add(kWorktreeCleanupSettleAfterChange),
      if (store.lastSweep() case final last?)
        last.startedAt.add(kWorktreeCleanupInterval),
    ];
    return floors.reduce((a, b) => a.isAfter(b) ? a : b);
  }

  /// Starts the automatic sweep when it is due. Does not wait for it: a sweep
  /// runs git per worktree and must not hold up the automations' own tick.
  bool startIfDue(DateTime now, {required DateTime availableSince}) {
    final due = nextDue(availableSince: availableSince);
    if (due == null || due.isAfter(now) || isSweeping) return false;
    unawaited(sweep(automatic: true).then((_) {}, onError: (Object _) {}));
    return true;
  }
}

final worktreeCleanupControllerProvider = Provider<WorktreeCleanupController>(
  WorktreeCleanupController.new,
);
