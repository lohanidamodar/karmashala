import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../workspaces/data/workspace_data.dart';
import 'package:karmashala_git/git.dart';
import '../data/git_data.dart';
import 'changes_providers.dart';

/// Opening, answering and triaging review threads, kept at the server (which
/// stamps and orders them). No argument takes a blob sha: every write computes
/// it from disk, and an unhashable file gets none.
class ReviewThreadService {
  ReviewThreadService(this._ref);

  final Ref _ref;

  DataClient get _client => _ref.read(dataClientProvider);

  /// Opens a thread against [path], anchored to the file as it is now; an
  /// unset [status] is the server's `defaultReviewStatus`.
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
    final trimmed =
        reviewBodyOf(body) ??
        (throw ArgumentError(
          'A review comment needs something written in it.',
        ));
    final sha = await currentBlobSha(repositoryId, path);
    if (sha == null) {
      throw StateError(
        'git could not hash `$path` in this repository, so there is nothing to '
        'anchor a comment to. A comment with no anchor could never be checked '
        'against the file later, which is the only thing that makes it worth '
        'keeping.',
      );
    }
    return _client.write(
      ReviewThreadOpen(
        id: _ref.read(idGeneratorProvider).newId(),
        repositoryId: repositoryId,
        anchor: ReviewAnchor(
          path: path,
          blobSha: sha,
          startLine: startLine,
          endLine: endLine,
          excerpt: excerpt,
        ),
        author: author,
        authorKind: authorKind,
        body: trimmed,
        status: status,
        sessionId: sessionId,
      ),
      domain: DataDomain.worktrees,
    );
  }

  /// Adds a reply. Null when the thread no longer exists.
  Future<ReviewThread?> reply({
    required String threadId,
    required String body,
    required String author,
    required ReviewAuthorKind authorKind,
  }) {
    final trimmed =
        reviewBodyOf(body) ??
        (throw ArgumentError('A reply needs something written in it.'));
    return _orGone(
      ReviewThreadReply(
        threadId: threadId,
        author: author,
        authorKind: authorKind,
        body: trimmed,
      ),
    );
  }

  /// Moves a thread's status. Null when the thread no longer exists.
  Future<ReviewThread?> setStatus(String threadId, ReviewThreadStatus status) =>
      _orGone(ReviewThreadSetStatus(threadId, status));

  Future<ReviewThread?> _orGone(DataRequest<ReviewThread> request) async {
    try {
      return await _client.write(request, domain: DataDomain.worktrees);
    } on DataRefused catch (refusal) {
      if (refusal.code == DataRefusalCode.notFound) return null;
      rethrow;
    }
  }

  ReviewThread? getById(String id) => _client.reviewThreads[id];

  /// One thread with its anchor checked, or null when it is gone.
  Future<AnchoredReviewThread?> anchored(String id) async {
    final thread = getById(id);
    if (thread == null) return null;
    final shas = await _shasFor(thread.repositoryId, [thread.anchor.path]);
    return AnchoredReviewThread(
      thread,
      thread.anchor.attachmentAgainst(shas[thread.anchor.path]),
    );
  }

  /// Every thread on [repositoryId], each held against the file it points at,
  /// in one git process whatever the count — the diff panel calls this on
  /// every working-tree change.
  Future<ReviewThreadIndex> indexFor(String repositoryId) async {
    final threads = [
      for (final thread in _client.reviewThreads.values)
        if (thread.repositoryId == repositoryId) thread,
    ]..sort(compareReviewThreads);
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
    final repository = _ref
        .read(workspaceDataProvider)
        .repository(repositoryId);
    if (repository == null) return const {};
    try {
      return await _ref.read(gitDataProvider).blobShas(repository.path, paths);
    } on Object {
      return const {};
    }
  }
}

final reviewThreadServiceProvider = Provider<ReviewThreadService>(
  ReviewThreadService.new,
);

/// Every review thread on [repositoryId], anchors already checked, read again
/// when a thread changes — here, from an agent, or at another client. Keyed,
/// so a diff tab reads the repository it was opened on.
final reviewThreadsByRepositoryProvider = FutureProvider.autoDispose
    .family<ReviewThreadIndex, String>((ref, repositoryId) async {
      final listening = ref
          .watch(dataClientProvider)
          .reviewThreads
          .changes
          .listen((_) => ref.invalidateSelf());
      ref.onDispose(listening.cancel);
      // An anchor moves with the file under it.
      final checkout = ref.read(workspaceDataProvider).repository(repositoryId);
      if (checkout != null) ref.watchCheckout(checkout.path);
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
