import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../cli_detection/data/cli_session_mutator.dart';
import 'package:agent_cli/read.dart';
import '../../notifications/application/notification_providers.dart';
import '../../notifications/domain/notification_request.dart';
import '../../sessions/application/session_actions.dart';

/// Deletes CLI session files **behind** the workspace change that asked for
/// it: the reversible half happens at once, the irreversible half reports back.
class CliStorePurgeRunner {
  CliStorePurgeRunner(this._ref);

  final Ref _ref;

  static final _log = AppLogger.named('projects.purge');

  final Set<Future<void>> _running = {};

  /// True once the container is gone: nothing may read a provider after that.
  bool _stopped = false;

  /// How many purges are still running. The Explorer does not draw this today —
  /// the row it deleted is already gone — but a test can assert on it.
  int get pending => _running.length;

  /// Completes when every purge started so far has finished. A loop rather than
  /// one `Future.wait`, because reporting a failure can outlive its batch.
  Future<void> get settled async {
    while (_running.isNotEmpty) {
      await Future.wait(_running.toList());
    }
  }

  /// Starts purging [sessions], attributed to [projectName] in whatever the
  /// user is told afterwards. Returns immediately.
  void start({
    required String projectName,
    required List<ImportedSession> sessions,
  }) {
    if (sessions.isEmpty || _stopped) return;
    late final Future<void> task;
    task = _run(projectName, sessions).whenComplete(() => _running.remove(task));
    _running.add(task);
  }

  Future<void> _run(
    String projectName,
    List<ImportedSession> sessions,
  ) async {
    CliDeleteReport report;
    try {
      report = await _ref.read(sessionActionsProvider).purgeFromCliStore(
        sessions,
      );
    } catch (error, stack) {
      // `deleteAll` reports rather than throws, so reaching here means the
      // store could not be addressed at all. Still the user's news.
      _log.warning('Deleting "$projectName" session files failed', error, stack);
      report = CliDeleteReport(
        deleted: 0,
        failures: [
          CliDeleteFailure(
            label: '${sessions.length} session file(s)',
            error: error,
          ),
        ],
      );
    }
    if (report.isComplete || _stopped) return;
    await _report(projectName, report);
  }

  /// Tells the user once, naming what is still on disk — the log and the OS
  /// toast, the only channel that reaches someone who has looked away.
  Future<void> _report(String projectName, CliDeleteReport report) async {
    final failures = report.failures;
    final named = failures.take(3).map((f) => f.label).toList();
    final more = failures.length - named.length;
    final left = more > 0
        ? '${named.join(' · ')} · +$more more'
        : named.join(' · ');
    final title = failures.length == 1
        ? '1 session file was left behind'
        : '${failures.length} session files were left behind';
    final body =
        '"$projectName" is out of the workspace, but these could not be '
        'deleted from the CLI store: $left';
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
  /// finish — half a delete is worse than a slow one — but nothing they learn
  /// is reported into a container that has gone.
  void dispose() => _stopped = true;
}

final cliStorePurgeRunnerProvider = Provider<CliStorePurgeRunner>((ref) {
  final runner = CliStorePurgeRunner(ref);
  ref.onDispose(runner.dispose);
  return runner;
});
