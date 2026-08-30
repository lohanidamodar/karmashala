import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/quick_open/repo_file_index.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../editor/application/code_editor_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../../repositories/application/repository_providers.dart';
import '../domain/file_change.dart';
import '../domain/git_commit.dart';
import '../domain/git_worktree.dart';
import 'changes_service.dart';
import 'git_providers.dart';

/// Provides the [ChangesService].
final changesServiceProvider = Provider<ChangesService>(
  (ref) => ChangesService(
    runnerFactory: ref.watch(commandRunnerFactoryProvider),
    environmentDao: ref.watch(executionEnvironmentDaoProvider),
    // A merge rewrites files in place, which the watcher does see — but only on
    // the platforms that have a recursive one, and only for a root that is
    // being watched at all.
    onWorkingTreeChanged: (repo) {
      final root = ref.read(editorActionsProvider).windowsPathFor(repo);
      if (root != null) ref.read(repoFileIndexProvider).touch(root);
    },
  ),
);

/// The repository whose changes are being reviewed, or `null`.
class SelectedRepositoryController extends Notifier<String?> {
  @override
  String? build() => null;
  void select(String? id) => state = id;
}

final selectedRepositoryIdProvider =
    NotifierProvider<SelectedRepositoryController, String?>(
      SelectedRepositoryController.new,
    );

/// The file within the selected repository whose diff is shown, or `null`.
class SelectedChangeFileController extends Notifier<String?> {
  @override
  String? build() => null;
  void select(String? path) => state = path;
}

final selectedChangeFileProvider =
    NotifierProvider<SelectedChangeFileController, String?>(
      SelectedChangeFileController.new,
    );

/// Working-tree changes for the selected repository.
final repositoryChangesProvider = FutureProvider.autoDispose<List<FileChange>>((
  ref,
) async {
  final id = ref.watch(selectedRepositoryIdProvider);
  if (id == null) return const [];
  final repo = ref.read(repositoryDaoProvider).getById(id);
  if (repo == null) return const [];
  return ref.read(changesServiceProvider).changes(repo.path);
});

/// The current branch of the selected repository.
final currentBranchProvider = FutureProvider.autoDispose<String?>((ref) async {
  final id = ref.watch(selectedRepositoryIdProvider);
  if (id == null) return null;
  final repo = ref.read(repositoryDaoProvider).getById(id);
  if (repo == null) return null;
  return ref.read(changesServiceProvider).currentBranch(repo.path);
});

/// The `origin` remote URL of the selected repository.
final repoRemoteUrlProvider = FutureProvider.autoDispose<String?>((ref) async {
  final id = ref.watch(selectedRepositoryIdProvider);
  if (id == null) return null;
  final repo = ref.read(repositoryDaoProvider).getById(id);
  if (repo == null) return null;
  return ref.read(changesServiceProvider).remoteUrl(repo.path);
});

/// Recent commits on the selected repository's current branch.
final recentCommitsProvider = FutureProvider.autoDispose<List<GitCommit>>((
  ref,
) async {
  final id = ref.watch(selectedRepositoryIdProvider);
  if (id == null) return const [];
  final repo = ref.read(repositoryDaoProvider).getById(id);
  if (repo == null) return const [];
  return ref.read(changesServiceProvider).log(repo.path, limit: 8);
});

/// The worktrees of the selected repository.
final repoWorktreesProvider = FutureProvider.autoDispose<List<GitWorktree>>((
  ref,
) async {
  final id = ref.watch(selectedRepositoryIdProvider);
  if (id == null) return const [];
  final repo = ref.read(repositoryDaoProvider).getById(id);
  if (repo == null) return const [];
  return ref.read(worktreeServiceProvider).list(repo.path);
});

/// Unified diff for the selected file in the selected repository.
final fileDiffProvider = FutureProvider.autoDispose<String>((ref) async {
  final file = ref.watch(selectedChangeFileProvider);
  if (file == null) return '';
  return ref.watch(fileDiffByPathProvider(file).future);
});

/// Unified diff for a specific [path] within the selected repository — used to
/// render each changed file's diff inline (expandable) in the Changes view.
final fileDiffByPathProvider = FutureProvider.autoDispose
    .family<String, String>((ref, path) async {
      final id = ref.watch(selectedRepositoryIdProvider);
      if (id == null) return '';
      final repo = ref.read(repositoryDaoProvider).getById(id);
      if (repo == null) return '';
      return ref.read(changesServiceProvider).diff(repo.path, path: path);
    });
