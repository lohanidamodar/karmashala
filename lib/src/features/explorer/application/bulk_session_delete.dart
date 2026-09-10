import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../cli_detection/data/cli_session_mutator.dart';
import 'package:agent_cli/read.dart';
import '../../notifications/application/notification_providers.dart';
import '../../notifications/domain/notification_request.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/application/session_providers.dart';
import 'package:karmashala_session/session.dart';

/// The rows one bulk delete is about, resolved *before* the confirmation so it
/// can name them, and held as objects so deleting the rows keeps the inputs.
class BulkDeleteTargets {
  const BulkDeleteTargets({this.natives = const [], this.imported = const []});

  final List<Session> natives;
  final List<ImportedSession> imported;

  int get count => natives.length + imported.length;
  bool get isEmpty => count == 0;

  /// Titles in the order the tree drew them, for the confirmation and for the
  /// "left behind" report.
  List<String> get titles => [
    for (final session in natives) session.title,
    for (final session in imported) session.displayTitle,
  ];
}

/// Deleting a ticked set of sessions: the workspace rows go first and
/// synchronously, the store purge behind them — a removed row is undone by
/// re-importing, a deleted transcript by nothing. Nothing here is a new batch.
class SessionBulkDelete {
  SessionBulkDelete(this._ref);

  final Ref _ref;

  /// The same logger a project delete's purge writes to: one channel for "a
  /// transcript was left behind", wherever the delete came from.
  static final _log = AppLogger.named('projects.purge');

  final Set<Future<void>> _running = {};

  /// True once the container is gone: nothing may read a provider after that.
  bool _stopped = false;

  /// How many purges are still running. A test's handle; the Explorer does not
  /// draw it, because the rows it deleted are already gone.
  int get pending => _running.length;

  /// Completes when every purge started so far has finished.
  Future<void> get settled async {
    while (_running.isNotEmpty) {
      await Future.wait(_running.toList());
    }
  }

  /// The rows behind [ids], each looked up in the table that owns it. An id
  /// matching neither is dropped rather than carried as a phantom.
  BulkDeleteTargets resolve(Iterable<String> ids) {
    final sessionDao = _ref.read(sessionDaoProvider);
    final importedDao = _ref.read(importedSessionDaoProvider);
    final natives = <Session>[];
    final imported = <ImportedSession>[];
    for (final id in ids) {
      final native = sessionDao.getById(id);
      if (native != null) {
        natives.add(native);
        continue;
      }
      final record = importedDao.getById(id);
      if (record != null) imported.add(record);
    }
    return BulkDeleteTargets(natives: natives, imported: imported);
  }

  /// Removes every row in [targets], and starts the transcript purge behind it
  /// when [deleteFromCli]. Returns before the purge does: there is no await
  /// between the confirmation and the rows leaving the tree.
  void run(BulkDeleteTargets targets, {required bool deleteFromCli}) {
    if (targets.isEmpty) return;
    _ref
        .read(sessionActionsProvider)
        .deleteSessionsFromWorkspace(
          natives: targets.natives,
          imported: targets.imported,
        );
    if (deleteFromCli) start(targets);
  }

  /// Starts the purge for [targets] and returns immediately. `CliStorePurgeRunner`
  /// would need a `startSessions` taking both lists to own this — a native row's
  /// transcript is a `DetectedSession`, not an [ImportedSession].
  void start(BulkDeleteTargets targets) {
    if (targets.isEmpty || _stopped) return;
    late final Future<void> task;
    task = _run(targets).whenComplete(() => _running.remove(task));
    _running.add(task);
  }

  Future<void> _run(BulkDeleteTargets targets) async {
    CliDeleteReport report;
    try {
      report = await _ref
          .read(sessionActionsProvider)
          .purgeSessionsFromCliStore(
            natives: targets.natives,
            imported: targets.imported,
          );
    } catch (error, stack) {
      // `deleteAll` reports rather than throws, so reaching here means the
      // store could not be addressed at all. Still the user's news.
      _log.warning('Deleting selected session files failed', error, stack);
      report = CliDeleteReport(
        deleted: 0,
        failures: [
          CliDeleteFailure(
            label: '${targets.count} session file(s)',
            error: error,
          ),
        ],
      );
    }
    if (report.isComplete || _stopped) return;
    await _report(targets.count, report);
  }

  /// Tells the user once, naming what is still on disk. A clean delete says
  /// nothing.
  Future<void> _report(int deleted, CliDeleteReport report) async {
    final failures = report.failures;
    final named = failures.take(3).map((f) => f.label).toList();
    final more = failures.length - named.length;
    final left = more > 0
        ? '${named.join(' · ')} · +$more more'
        : named.join(' · ');
    final title = failures.length == 1
        ? '1 session file was left behind'
        : '${failures.length} session files were left behind';
    final subject = deleted == 1 ? '1 session is' : '$deleted sessions are';
    final body =
        '$subject out of the workspace, but these could not be deleted '
        'from the CLI store: $left';
    _log.warning(
      '$title — $body '
      '(${report.deleted} deleted; first error: ${failures.first.error})',
    );
    if (_stopped) return;
    await _ref
        .read(notificationPresenterProvider)
        .show(NotificationRequest(title: title, body: body));
  }

  /// Stops the runner reading providers. In-flight file deletes are left to
  /// finish — half a delete is worse than a slow one.
  void dispose() => _stopped = true;
}

final sessionBulkDeleteProvider = Provider<SessionBulkDelete>((ref) {
  final runner = SessionBulkDelete(ref);
  ref.onDispose(runner.dispose);
  return runner;
});
