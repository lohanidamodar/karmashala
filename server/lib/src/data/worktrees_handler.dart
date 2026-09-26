import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_git/store.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_store/database.dart';

/// The git side tables at the server — each checkout's worktree setup, the
/// verdict of every worktree's setup run, review threads: validates, writes,
/// and says what changed.
class WorktreesHandler {
  WorktreesHandler(AppDatabase db, this._now)
    : _setups = WorktreeSetupDao(db),
      _threads = ReviewThreadDao(db),
      _repositories = RepositoryDao(db);

  final WorktreeSetupDao _setups;
  final ReviewThreadDao _threads;
  final RepositoryDao _repositories;
  final DateTime Function() _now;

  WorktreesSnapshot list() => WorktreesSnapshot(
    setups: _setups.getAll(),
    runs: _setups.allRuns(),
    threads: _threads.all(),
  );

  /// What goes, by the schema's cascades, with checkouts [ids] — read before
  /// they are deleted, told after. The keys the cascade does not reach (the
  /// teardown, the waiting flag) are cleared then too.
  List<DataChange> Function() checkoutsGoing(List<String> ids) {
    final going = ids.toSet();
    final setups = [
      for (final id in going)
        if (_setups.get(id) case final setup
            when setup.isNotEmpty ||
                setup.teardown.isNotEmpty ||
                !setup.startAgentBeforeSetup)
          id,
    ];
    final changes = <DataChange>[
      for (final id in setups) WorktreeSetupChanged(id, null),
      for (final run in _setups.allRuns())
        if (going.contains(run.repositoryId)) WorktreeRunRemoved(run.key),
      for (final thread in _threads.all())
        if (going.contains(thread.repositoryId)) ReviewThreadRemoved(thread.id),
    ];
    return () {
      setups.forEach(_setups.clear);
      return changes;
    };
  }

  /// What checkout [repositoryId] has set up, for a worktree the server makes.
  WorktreeSetup setupOf(String repositoryId) => _setups.get(repositoryId);

  DataAck save(WorktreeSetupSave request, List<DataChange> changes) {
    _requireCheckout(request.repositoryId);
    _setups.save(request.repositoryId, request.setup, _now());
    changes.add(_setupNow(request.repositoryId));
    return const DataAck();
  }

  DataAck clear(WorktreeSetupClear request, List<DataChange> changes) {
    _requireCheckout(request.repositoryId);
    _setups.clear(request.repositoryId);
    changes.add(_setupNow(request.repositoryId));
    return const DataAck();
  }

  DataAck record(WorktreeSetupReport report, List<DataChange> changes) {
    _requireCheckout(report.repositoryId);
    _setups.record(report);
    changes.add(WorktreeRunRecorded(report));
    return const DataAck();
  }

  ReviewThread open(ReviewThreadOpen request, List<DataChange> changes) {
    final body = _body(request.body);
    if (request.id.trim().isEmpty) {
      throw const DataRefused.invalid('a review thread needs an id');
    }
    if (_threads.getById(request.id) != null) {
      throw DataRefused.invalid('a thread with id ${request.id} exists');
    }
    _requireCheckout(request.repositoryId);
    final anchor = request.anchor;
    final start = anchor.startLine;
    final thread = _threads.open(
      id: request.id,
      repositoryId: request.repositoryId,
      // A single-line anchor stores the same number twice.
      anchor: ReviewAnchor(
        path: anchor.path,
        blobSha: anchor.blobSha,
        startLine: start,
        endLine: start == null ? null : (anchor.endLine ?? start),
        excerpt: anchor.excerpt,
      ),
      status:
          _settable(request.status) ?? defaultReviewStatus(request.authorKind),
      author: request.author,
      authorKind: request.authorKind,
      body: body,
      sessionId: request.sessionId,
      now: _now(),
    );
    changes.add(ReviewThreadChanged(thread));
    return thread;
  }

  ReviewThread reply(ReviewThreadReply request, List<DataChange> changes) {
    final body = _body(request.body);
    final thread =
        _threads.reply(
          threadId: request.threadId,
          author: request.author,
          authorKind: request.authorKind,
          body: body,
          now: _now(),
        ) ??
        (throw DataRefused.notFound('no review thread ${request.threadId}'));
    changes.add(ReviewThreadChanged(thread));
    return thread;
  }

  ReviewThread setStatus(
    ReviewThreadSetStatus request,
    List<DataChange> changes,
  ) {
    final status =
        _settable(request.status) ??
        (throw const DataRefused.invalid(
          'a thread is open, shouldFix, dismissed or resolved',
        ));
    final thread =
        _threads.setStatus(request.threadId, status, now: _now()) ??
        (throw DataRefused.notFound('no review thread ${request.threadId}'));
    changes.add(ReviewThreadChanged(thread));
    return thread;
  }

  WorktreeSetupChanged _setupNow(String repositoryId) =>
      WorktreeSetupChanged(repositoryId, _setups.getAll()[repositoryId]);

  void _requireCheckout(String id) {
    if (_repositories.getById(id) == null) {
      throw DataRefused.notFound('no checkout with id $id');
    }
  }

  static String _body(String body) =>
      reviewBodyOf(body) ??
      (throw const DataRefused.invalid(
        'A review comment needs something written in it.',
      ));

  static ReviewThreadStatus? _settable(ReviewThreadStatus? status) =>
      status == null || !ReviewThreadStatus.settable.contains(status.name)
      ? null
      : status;
}
