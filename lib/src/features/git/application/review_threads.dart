import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../repositories/application/repository_providers.dart';
import '../data/review_thread_dao.dart';
import '../domain/review_thread.dart';
import 'changes_providers.dart';

/// Opening, answering and triaging review threads, and holding every anchor
/// against the file it points at.
///
/// ## Why the caller never supplies the blob sha
///
/// Every write path here computes the anchor's sha itself, from the file on
/// disk, at the moment the thread is opened. No argument accepts one. That is
/// deliberate and it is the load-bearing rule of the feature: a sha handed in
/// by a caller is a claim about content that caller may not have been looking
/// at — an agent that read the file three turns ago, a stale MCP argument, a
/// retry — and an anchor built from it would attach cleanly to bytes nobody
/// reviewed. The sha is not decoration on the anchor; it *is* the anchor's
/// truth condition, so it comes from the same place the truth does.
///
/// A file git will not hash has no anchor, so no thread is opened and the
/// caller is told why. That is better than an anchor with a placeholder sha,
/// which would be permanently detached from everything including itself.
class ReviewThreadService {
  ReviewThreadService(this._ref);

  final Ref _ref;

  ReviewThreadDao get _dao => _ref.read(reviewThreadDaoProvider);

  /// Opens a thread against [path] in [repositoryId].
  ///
  /// [startLine]/[endLine] are line numbers in the file **as it is right now**
  /// — which is the same content the sha is taken from, so the two agree by
  /// construction. Omit them for a file-level thread.
  ///
  /// [status] defaults by author: a person writing on a diff has already
  /// triaged what they wrote and gets [ReviewThreadStatus.shouldFix]; an agent
  /// gets [ReviewThreadStatus.open], because "this should be fixed" is the
  /// judgement a human review exists to make and an agent asserting it would be
  /// filing its own findings straight into the queue that gets sent back to an
  /// agent.
  Future<ReviewThread> open({
    required String repositoryId,
    required String path,
    required String body,
    required String author,
    required ReviewAuthorKind authorKind,
    int? startLine,
    int? endLine,
    String? excerpt,
    String? sessionId,
    ReviewThreadStatus? status,
  }) async {
    final trimmed = body.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('A review comment needs something written in it.');
    }
    final sha = await currentBlobSha(repositoryId, path);
    if (sha == null) {
      throw StateError(
        'git could not hash `$path` in this repository, so there is nothing to '
        'anchor a comment to. A comment with no anchor could never be checked '
        'against the file later, which is the only thing that makes it worth '
        'keeping.',
      );
    }
    final now = _ref.read(clockProvider).nowUtc();
    final thread = _dao.open(
      id: _ref.read(idGeneratorProvider).newId(),
      repositoryId: repositoryId,
      anchor: ReviewAnchor(
        path: path,
        blobSha: sha,
        startLine: startLine,
        // A single-line anchor stores the same number twice rather than a null
        // end, so a range is always read the same way.
        endLine: startLine == null ? null : (endLine ?? startLine),
        excerpt: excerpt,
      ),
      status:
          status ??
          (authorKind == ReviewAuthorKind.user
              ? ReviewThreadStatus.shouldFix
              : ReviewThreadStatus.open),
      author: author,
      authorKind: authorKind,
      body: trimmed,
      sessionId: sessionId,
      now: now,
    );
    _bump();
    return thread;
  }

  /// Adds a reply. Returns null when the thread no longer exists.
  ReviewThread? reply({
    required String threadId,
    required String body,
    required String author,
    required ReviewAuthorKind authorKind,
  }) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('A reply needs something written in it.');
    }
    final thread = _dao.reply(
      threadId: threadId,
      author: author,
      authorKind: authorKind,
      body: trimmed,
      now: _ref.read(clockProvider).nowUtc(),
    );
    if (thread != null) _bump();
    return thread;
  }

  /// Moves a thread's status. Returns null when the thread no longer exists.
  ReviewThread? setStatus(String threadId, ReviewThreadStatus status) {
    final thread = _dao.setStatus(
      threadId,
      status,
      now: _ref.read(clockProvider).nowUtc(),
    );
    if (thread != null) _bump();
    return thread;
  }

  ReviewThread? getById(String id) => _dao.getById(id);

  /// One thread with its anchor checked, or null when it is gone.
  Future<AnchoredReviewThread?> anchored(String id) async {
    final thread = _dao.getById(id);
    if (thread == null) return null;
    final shas = await _shasFor(thread.repositoryId, [thread.anchor.path]);
    return AnchoredReviewThread(
      thread,
      thread.anchor.attachmentAgainst(shas[thread.anchor.path]),
    );
  }

  /// Every thread on [repositoryId], each one already held against the file it
  /// points at.
  ///
  /// **Two database statements and one git process, whatever the thread
  /// count.** This is what the diff panel calls, and the panel redraws whenever
  /// the working tree does; a per-thread query or a per-thread `hash-object`
  /// would put the whole review history of a repository between a git poll and
  /// the next frame. Guarded by `review_thread_cost_test`.
  Future<ReviewThreadIndex> indexFor(String repositoryId) async {
    final threads = _dao.forRepository(repositoryId);
    if (threads.isEmpty) return ReviewThreadIndex.empty;
    final paths = <String>{for (final thread in threads) thread.anchor.path};
    final shas = await _shasFor(repositoryId, paths.toList()..sort());
    return ReviewThreadIndex([
      for (final thread in threads)
        AnchoredReviewThread(
          thread,
          thread.anchor.attachmentAgainst(shas[thread.anchor.path]),
        ),
    ]);
  }

  /// The current content fingerprint of [path], or null when git could not be
  /// asked. Public because opening a thread and checking one are the same
  /// question asked at two moments.
  Future<String?> currentBlobSha(String repositoryId, String path) async =>
      (await _shasFor(repositoryId, [path]))[path];

  /// Best-effort: a repository that is gone, or a git that will not answer,
  /// yields an empty map and therefore [ReviewThreadAttachment.unknown] — never
  /// a silent "attached".
  Future<Map<String, String>> _shasFor(
    String repositoryId,
    List<String> paths,
  ) async {
    final repository = _ref.read(repositoryDaoProvider).getById(repositoryId);
    if (repository == null) return const {};
    try {
      return await _ref
          .read(changesServiceProvider)
          .blobShas(repository.path, paths);
    } on Object {
      return const {};
    }
  }

  /// Tells the read providers that something changed.
  ///
  /// A revision counter rather than an invalidation of a named provider,
  /// because the writers are not all in this process's UI: an agent calling
  /// `review_thread_reply` over MCP goes through this same service, and the
  /// panel a human is looking at has to notice.
  void _bump() => _ref.read(reviewThreadRevisionProvider.notifier).bump();
}

final reviewThreadDaoProvider = Provider<ReviewThreadDao>(
  (ref) => ReviewThreadDao(ref.watch(databaseProvider)),
);

final reviewThreadServiceProvider = Provider<ReviewThreadService>(
  ReviewThreadService.new,
);

/// Bumped by every write, watched by every read. See [ReviewThreadService].
class ReviewThreadRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state = state + 1;
}

final reviewThreadRevisionProvider =
    NotifierProvider<ReviewThreadRevision, int>(ReviewThreadRevision.new);

/// Every review thread on the selected repository, anchors already checked.
///
/// One provider for the whole panel rather than one lookup per rendered line:
/// each `_DiffLineTile` reads its threads out of this index by line number. The
/// implementation it replaces had every tile filter the full annotation list on
/// every build, which was survivable only because the list lived in memory and
/// was cleared constantly.
final repositoryReviewThreadsProvider =
    FutureProvider.autoDispose<ReviewThreadIndex>((ref) async {
      final repositoryId = ref.watch(selectedRepositoryIdProvider);
      if (repositoryId == null) return ReviewThreadIndex.empty;
      ref.watch(reviewThreadRevisionProvider);
      return ref.read(reviewThreadServiceProvider).indexFor(repositoryId);
    });
