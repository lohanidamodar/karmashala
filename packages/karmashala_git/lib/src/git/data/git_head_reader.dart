import 'git_dir.dart';
import 'git_files.dart';

/// What a `HEAD` file names, as a row would say it: the branch for
/// `ref: refs/heads/<name>`, the short sha for a detached one, and **null for
/// anything else** — absent, empty, or not what git writes there.
String? gitHeadLabel(String? text) {
  if (text == null) return null;
  final line = text
      .split(RegExp(r'[\r\n]'))
      .map((l) => l.trim())
      .firstWhere((l) => l.isNotEmpty, orElse: () => '');
  if (line.startsWith('ref:')) {
    final ref = line.substring('ref:'.length).trim();
    const heads = 'refs/heads/';
    final name = ref.startsWith(heads)
        ? ref.substring(heads.length)
        : ref.startsWith('refs/')
        ? ref.substring('refs/'.length)
        : ref;
    return name.isEmpty ? null : name;
  }
  return _sha.hasMatch(line) ? line.substring(0, shortShaLength) : null;
}

/// What `git rev-parse --short` answers in a small repository.
const shortShaLength = 7;

/// SHA-1, or the 64 digits of a SHA-256 repository.
final _sha = RegExp(r'^(?:[0-9a-f]{40}|[0-9a-f]{64})$');

/// **Which branch is checked out — answered with no process at all.**
///
/// One file read for an ordinary clone. A worktree or a submodule has a `.git`
/// *file* naming its git directory, which costs two more. No `stat`, and no
/// parent walk: this answers for a repository's own root, which is what the
/// caller holds. Reads the host's own filesystem and nothing else — the caller
/// decides a path is local before asking.
class GitHeadReader {
  const GitHeadReader({required this.files});

  final GitFiles files;

  Future<String?> read(String root) async {
    final context = gitPathContextFor(root);
    final dotGit = context.join(root, '.git');
    final own = gitHeadLabel(
      await files.readString(context.join(dotGit, 'HEAD')),
    );
    if (own != null) return own;
    final gitDir = gitDirNamedIn(
      await files.readString(dotGit),
      host: root,
      context: context,
      hostPathOf: sameEnvironmentPath,
    );
    if (gitDir == null) return null;
    return gitHeadLabel(
      await files.readString(context.join(context.normalize(gitDir), 'HEAD')),
    );
  }
}

/// [GitHeadReader]'s answers, kept per repository root for as long as the
/// caller's [read] `stamp` stands. The stamp is whatever the caller counts
/// changes by: the same stamp is the same answer and no file read, a new one
/// reads that root again and no other.
class GitHeadCache {
  GitHeadCache(this.reader, {this.capacity = 4096});

  final GitHeadReader reader;

  /// A workspace that outgrows it starts over.
  final int capacity;

  // The future, not its value: two rows asking in one frame share one read.
  final _entries = <String, ({Object? stamp, Future<String?> label})>{};

  int get length => _entries.length;

  Future<String?> read(String root, {required Object? stamp}) {
    final entry = _entries[root];
    if (entry != null && entry.stamp == stamp) return entry.label;
    if (entry == null && _entries.length >= capacity) _entries.clear();
    final label = reader.read(root);
    _entries[root] = (stamp: stamp, label: label);
    return label;
  }
}
