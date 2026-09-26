import 'package:riverpod/riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../repositories/application/repository_providers.dart';
import '../data/review_thread_dao.dart';
import 'package:karmashala_git/git.dart';
import 'changes_providers.dart';

/// Opening, answering and triaging review threads. No argument takes a blob
/// sha: every write computes it from disk, and an unhashable file gets none.
class ReviewThreadService {
  ReviewThreadService(this._ref);

  final Ref _ref;

  ReviewThreadDao get _dao => _ref.read(reviewThreadDaoProvider);

  /// Opens a thread against [path], anchored to the file as it is now; [status]
  /// defaults by author, since an agent must not triage its own findings.
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
        // A single-line anchor stores the same number twice, so a range is
        // always read the same way.
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

  /// Every thread on [repositoryId], each already held against the file it
  /// points at, in two database statements and one git process whatever the
  /// thread count — the diff panel calls this on every working-tree change.
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
  /// asked.
  Future<String?> currentBlobSha(String repositoryId, String path) async =>
      (await _shasFor(repositoryId, [path]))[path];

  /// Best-effort: a git that will not answer yields an empty map and therefore
  /// [ReviewThreadAttachment.unknown], never a silent "attached".
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

  /// Tells the read providers that something changed. A revision counter, not
  /// an invalidation, because an agent writing over MCP goes through this same
  /// service and the panel a human is looking at has to notice.
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

/// Every review thread on [repositoryId], anchors already checked. Keyed, so a
/// diff tab reads the repository it was opened on rather than whichever row the
/// sidebar is pointed at now.
final reviewThreadsByRepositoryProvider = FutureProvider.autoDispose
    .family<ReviewThreadIndex, String>((ref, repositoryId) async {
      ref.watch(reviewThreadRevisionProvider);
      return ref.read(reviewThreadServiceProvider).indexFor(repositoryId);
    });

/// The selected repository's threads — the sidebar's own case. One provider for
/// the whole panel: each `_DiffLineTile` reads its threads out of this index by
/// line number rather than filtering the whole list per build.
final repositoryReviewThreadsProvider =
    FutureProvider.autoDispose<ReviewThreadIndex>((ref) async {
      final repositoryId = ref.watch(selectedRepositoryIdProvider);
      if (repositoryId == null) return ReviewThreadIndex.empty;
      return ref.watch(reviewThreadsByRepositoryProvider(repositoryId).future);
    });

/// The threads a surface should draw: its own repository's when it names one,
/// and the sidebar's selection when it does not.
FutureProvider<ReviewThreadIndex> reviewThreadsOf(String? repositoryId) =>
    repositoryId == null
    ? repositoryReviewThreadsProvider
    : reviewThreadsByRepositoryProvider(repositoryId);
