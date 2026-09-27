import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:karmashala_files/values.dart';
import 'package:riverpod/riverpod.dart';

import '../../../features/checkpoints/application/checkpoint_providers.dart';
import '../../../features/file_explorer/application/file_explorer_providers.dart';
import '../../../features/files/data/files_client.dart';
import '../../../features/git/data/git_data.dart';
import '../../../features/sessions/application/session_ui_providers.dart';

/// A file in the indexed repository: its path relative to the root (the thing
/// worth searching and showing) and where it is, to open it.
class IndexedFile {
  const IndexedFile({required this.relativePath, required this.path});

  final String relativePath;
  final EnvironmentPath path;

  /// The last segment — what a query usually means.
  String get name {
    final cut = relativePath.lastIndexOf('/');
    return cut < 0 ? relativePath : relativePath.substring(cut + 1);
  }
}

/// **Quick Open's files, asked of the server** (slice 3c): the server walks
/// the checkout wherever it is, keeps the walk, and walks again when it moved.
/// This keeps the last answer per root so the palette's first frame draws at
/// once, and knows when that answer is worth asking again: a checkout touched
/// (a write, a worktree, an agent's turn ending there), a session or a
/// checkpoint recorded.
class RepoFileIndex {
  RepoFileIndex(this._files);

  final FilesClient _files;
  final Map<EnvironmentPath, List<IndexedFile>> _answers = {};
  final Set<EnvironmentPath> _stale = {};
  final Map<EnvironmentPath, Future<List<IndexedFile>>> _asking = {};
  final _changes = StreamController<EnvironmentPath>.broadcast();
  var _disposed = false;

  /// A root whose answer landed or went stale. The open palette listens.
  Stream<EnvironmentPath> get changes => _changes.stream;

  /// The last answer for [root], without asking.
  List<IndexedFile> cached(EnvironmentPath root) => _answers[root] ?? const [];

  bool isIndexed(EnvironmentPath root) => _answers.containsKey(root);

  /// Whether the last answer for [root] is still worth drawing without
  /// asking again.
  bool isFresh(EnvironmentPath root) =>
      _answers.containsKey(root) && !_stale.contains(root);

  /// Asks the server for [root]'s files unless the last answer is fresh,
  /// sharing an ask in flight. A refusal answers what was cached.
  Future<List<IndexedFile>> index(EnvironmentPath root) {
    if (_disposed || isFresh(root)) return Future.value(cached(root));
    // A block, not an arrow: `remove` answers the future itself, and one
    // `whenComplete` is handed back it waits for — for ever.
    return _asking[root] ??= _ask(root).whenComplete(() {
      _asking.remove(root);
    });
  }

  Future<List<IndexedFile>> _ask(EnvironmentPath root) async {
    _stale.remove(root);
    final RepoFiles answer;
    try {
      answer = await _files.index(root);
    } on FilesException {
      return cached(root);
    }
    if (_disposed) return const [];
    final files = [
      for (final relative in answer.files)
        IndexedFile(relativePath: relative, path: answer.pathOf(root, relative)),
    ];
    _answers[root] = files;
    _emit(root);
    return files;
  }

  /// Marks every root at or under [path] stale.
  void touch(EnvironmentPath path) {
    for (final root in _answers.keys) {
      if (isUnderFileTreeRoot(root, path) || isUnderFileTreeRoot(path, root)) {
        if (_stale.add(root)) _emit(root);
      }
    }
  }

  /// Marks every root stale — what a signal that names no checkout can say.
  void touchAll() {
    for (final root in _answers.keys) {
      if (_stale.add(root)) _emit(root);
    }
  }

  void _emit(EnvironmentPath root) {
    if (!_changes.isClosed) _changes.add(root);
  }

  void dispose() {
    _disposed = true;
    unawaited(_changes.close());
  }
}

/// One index for the app, so opening Quick Open twice does not ask twice.
final repoFileIndexProvider = Provider<RepoFileIndex>((ref) {
  final index = RepoFileIndex(ref.watch(filesClientProvider));
  ref.onDispose(index.dispose);
  ref.listen(sessionsRevisionProvider, (_, _) => index.touchAll());
  ref.listen(checkpointsRevisionProvider, (_, _) => index.touchAll());
  final touches = ref
      .watch(gitDataProvider)
      .touches
      .listen((touched) => index.touch(touched.directory));
  ref.onDispose(touches.cancel);
  return index;
});

/// The root Quick Open indexes files under: the selected repository, where
/// its own environment has it. Null when nothing is selected.
final quickOpenFileRootProvider = Provider<EnvironmentPath?>(
  (ref) => ref.watch(fileTreeRootProvider),
);
