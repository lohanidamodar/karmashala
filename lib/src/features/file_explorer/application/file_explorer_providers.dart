import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../editor/application/code_editor_providers.dart';
import '../../git/application/changes_providers.dart';
import '../../repositories/application/repository_providers.dart';
import '../data/file_listing_service.dart';

final fileListingServiceProvider = Provider<FileListingService>(
  (ref) => const FileListingService(),
);

/// The selected repository's root as a Windows-host path (for the file
/// explorer), or `null` if none is selected / it can't be resolved.
final selectedRepoWindowsRootProvider = Provider<String?>((ref) {
  final id = ref.watch(selectedRepositoryIdProvider);
  if (id == null) return null;
  final repo = ref.watch(repositoryDaoProvider).getById(id);
  if (repo == null) return null;
  return ref.read(editorActionsProvider).windowsPathFor(repo.path);
});

/// Directory contents for [windowsDir], listed on the Windows host.
final directoryListingProvider = FutureProvider.autoDispose
    .family<List<DirEntry>, String>((ref, windowsDir) async {
      return ref.read(fileListingServiceProvider).list(windowsDir);
    });
