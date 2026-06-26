import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/process/command_runner_providers.dart';
import '../../environments/application/environment_providers.dart';
import '../../repositories/application/repository_providers.dart';
import '../domain/file_change.dart';
import 'changes_service.dart';

/// Provides the [ChangesService].
final changesServiceProvider = Provider<ChangesService>(
  (ref) => ChangesService(
    runnerFactory: ref.watch(commandRunnerFactoryProvider),
    environmentDao: ref.watch(executionEnvironmentDaoProvider),
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

/// Unified diff for the selected file in the selected repository.
final fileDiffProvider = FutureProvider.autoDispose<String>((ref) async {
  final id = ref.watch(selectedRepositoryIdProvider);
  final file = ref.watch(selectedChangeFileProvider);
  if (id == null || file == null) return '';
  final repo = ref.read(repositoryDaoProvider).getById(id);
  if (repo == null) return '';
  return ref.read(changesServiceProvider).diff(repo.path, path: file);
});
