import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_git/repositories.dart' show samePath;
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';

/// Each checkout's worktree setup and every worktree's setup verdict, as the
/// server keeps them: read from this app's copy; a write lands in it at once
/// and at the server after (a refusal is logged and the copy read again).
class WorktreeSetupData {
  WorktreeSetupData(this._client);

  static final _log = AppLogger.named('worktree.setup');

  final DataClient _client;

  /// Fires after a setup or a verdict changed — here or at another client.
  Stream<void> get changes => Stream.multi((out) {
    final listening = [
      _client.worktreeSetups.changes.listen(out.addSync),
      _client.worktreeRuns.changes.listen(out.addSync),
    ];
    out.onCancel = () => Future.wait([for (final s in listening) s.cancel()]);
  }, isBroadcast: true);

  /// The setup for [repositoryId] — empty when nothing is configured.
  WorktreeSetup get(String repositoryId) =>
      _client.worktreeSetups[repositoryId] ?? const WorktreeSetup();

  /// Every configured checkout, by repository id.
  Map<String, WorktreeSetup> getAll() => _client.worktreeSetups.asMap;

  /// The recorded verdicts for [repositoryId]'s worktrees, newest first.
  List<WorktreeSetupReport> runsFor(String repositoryId) => [
    for (final run in _client.worktreeRuns.values)
      if (run.repositoryId == repositoryId) run,
  ]..sort(compareSetupRuns);

  /// The newest [limit] runs across every checkout.
  List<WorktreeSetupReport> recentRuns({int limit = 8}) => ([
    ..._client.worktreeRuns.values,
  ]..sort(compareSetupRuns)).take(limit).toList();

  /// When [worktree] was made, by its setup record — null when none names it.
  DateTime? createdAt(EnvironmentPath worktree) {
    for (final run in _client.worktreeRuns.values) {
      if (run.environmentId == worktree.environmentId &&
          samePath(run.worktreePath, worktree.path)) {
        return run.ranAt;
      }
    }
    return null;
  }

  void save(String repositoryId, WorktreeSetup setup) {
    _client.worktreeSetups.setLocal(repositoryId, setup.isEmpty ? null : setup);
    _send(WorktreeSetupSave(repositoryId, setup));
  }

  void clear(String repositoryId) {
    _client.worktreeSetups.setLocal(repositoryId, null);
    _send(WorktreeSetupClear(repositoryId));
  }

  /// Records how a worktree this app made was set up.
  void record(WorktreeSetupReport report) {
    _client.worktreeRuns.setLocal(report.key, report);
    _send(WorktreeSetupRecord(report));
  }

  void _send<R>(DataRequest<R> request) => unawaited(
    _client
        .write(request, domain: DataDomain.worktrees)
        .then<void>(
          (_) {},
          onError: (Object error) =>
              _log.warning('${request.kind} was refused: $error'),
        ),
  );
}

final worktreeSetupDataProvider = Provider<WorktreeSetupData>(
  (ref) => WorktreeSetupData(ref.watch(dataClientProvider)),
);
