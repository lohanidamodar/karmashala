import 'package:path/path.dart' as p;

import 'git_dir.dart';
import 'git_files.dart';

/// One fact read off disk, or the admission that the files could not answer it.
///
/// [known] is the whole type: `null` alone cannot separate "this clone has no
/// `origin`" from "these bytes did not tell me", and the two need opposite
/// responses — an answer, or a reason to spend a process.
class ReadFact<T> {
  const ReadFact.known(this.value) : known = true;
  const ReadFact.unknown() : value = null, known = false;

  /// Whether the files answered at all.
  final bool known;

  /// The answer, meaningful only when [known].
  final T? value;

  @override
  String toString() => known ? 'ReadFact($value)' : 'ReadFact(unknown)';
}

/// What `.git` says about `origin`, read instead of asked.
///
/// Two file reads instead of two subprocesses: on Windows `CreateProcessW` runs
/// on the *calling thread* before the future exists, and a WSL checkout crosses
/// the 9p boundary once per process.
///
/// **Every uncertainty is a [ReadFact.unknown], and the caller then asks git.** A
/// wrong answer here is worse than a slow one: the URL decides whether a row
/// looks for a pull request, and `origin/HEAD` is the ahead/behind base.
class GitOriginReader {
  GitOriginReader({required this.files, required this.hostPathOf});

  final GitFiles files;

  /// How a path inside the repository's environment is spelled for this
  /// process. Answers null for a filesystem this process cannot open, and the
  /// whole reading is then unknown.
  final HostPathOrNone hostPathOf;

  /// `origin`'s URL and `origin/HEAD` for the working tree at [checkout],
  /// written as its own environment spells it.
  ///
  /// Two reads for an ordinary checkout, up to four when `.git` is a *file*
  /// naming the real git directory — which is what a worktree and a submodule have.
  Future<({ReadFact<String?> url, ReadFact<String?> head})> read(
    String checkout,
  ) async {
    const unknown = (
      url: ReadFact<String?>.unknown(),
      head: ReadFact<String?>.unknown(),
    );
    final host = hostPathOf(checkout);
    if (host == null) return unknown;
    final context = gitPathContextFor(host);

    // No `stat` in front of it: on a `\\wsl.localhost` share asking *whether* a
    // file exists costs the same as reading it, so a failed read is the check.
    final dotGit = context.join(host, '.git');
    var common = dotGit;
    var config = await files.readString(context.join(common, 'config'));
    if (config == null) {
      // Either not a repository at all, or a working tree whose `.git` is a
      // file: `gitdir: <path to the real git directory>`.
      final resolved = gitDirNamedIn(
        await files.readString(dotGit),
        host: host,
        context: context,
        hostPathOf: hostPathOf,
      );
      if (resolved == null) return unknown;
      common = _commonDirOf(resolved, context);
      config = await files.readString(context.join(common, 'config'));
      if (config == null) return unknown;
    }

    final url = _originUrlIn(config);
    // An unreadable URL hands the **whole** reading to git: a known `origin/HEAD`
    // beside an unknown URL is the one genuinely wrong answer available here.
    if (!url.known) {
      return (url: url, head: const ReadFact<String?>.unknown());
    }
    // A clone with no `origin` has no `origin/HEAD` either, and nothing to
    // read to learn it.
    if (url.value == null) {
      return (url: url, head: const ReadFact<String?>.known(null));
    }
    return (url: url, head: await _originHeadIn(common, context));
  }

  /// **The git directory this working tree shares with the rest of its
  /// family**, or null when the files could not say.
  ///
  /// Two worktrees of one clone answer the same string and two unrelated
  /// checkouts never do, so this is the key for asking `git worktree list` once
  /// per family rather than once per row. One `typeOf`, one more read for a
  /// worktree, and no process at all.
  ///
  /// **Null is "we could not tell", never "it is its own family"** — an SSH
  /// checkout, an unrecognised `.git`, a distribution that did not answer.
  Future<String?> commonDirectory(String checkout) async {
    final host = hostPathOf(checkout);
    if (host == null) return null;
    final context = gitPathContextFor(host);
    final dotGit = context.join(host, '.git');
    // The `.git` of a clone is a directory and of a worktree is a file — the
    // same discriminator `GitPresenceReader` uses, and the one shape question
    // that cannot be answered by reading.
    switch (await files.typeOf(dotGit)) {
      case PathEntry.directory:
        return dotGit;
      case PathEntry.file:
        final resolved = gitDirNamedIn(
          await files.readString(dotGit),
          host: host,
          context: context,
          hostPathOf: hostPathOf,
        );
        return resolved == null ? null : _commonDirOf(resolved, context);
      case PathEntry.none:
        return null;
    }
  }

  /// The git directory two worktrees of one clone **share**.
  ///
  /// A worktree's own git directory is `<common>/worktrees/<name>`; anything else
  /// — a submodule, a bare `GIT_DIR` — is already its own common directory.
  String _commonDirOf(String gitDir, p.Context context) {
    final parts = gitDir.split(RegExp(r'[\\/]'));
    if (parts.length < 2) return gitDir;
    if (parts[parts.length - 2] != 'worktrees') return gitDir;
    return parts.sublist(0, parts.length - 2).join(context.separator);
  }

  /// `remote.origin.url` as `.git/config` records it.
  ///
  /// Unknown — ask git — for an `[include]`/`[includeIf]` section, for a
  /// `[url "…"]` section where `insteadOf` rewriting lives that a read cannot
  /// expand, and for a value that is not URL-shaped, which is a local path or a
  /// shorthand only git can tell apart. No `[remote "origin"]` at all is a
  /// confident **null**; a section with no `url` is not a shape git writes.
  ReadFact<String?> _originUrlIn(String config) {
    if (_indirection.hasMatch(config)) return const ReadFact.unknown();
    var inOrigin = false;
    var sawSection = false;
    for (final raw in config.split(RegExp(r'[\r\n]'))) {
      var line = raw.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith(';')) {
        continue;
      }
      if (line.startsWith('[')) {
        final close = line.indexOf(']');
        if (close < 0) return const ReadFact.unknown();
        final header = line.substring(1, close).trim();
        inOrigin = _isOriginRemote(header);
        if (inOrigin) sawSection = true;
        // Git accepts `[section "sub"] key = value` on one line.
        line = line.substring(close + 1).trim();
        if (line.isEmpty) continue;
      }
      if (!inOrigin) continue;
      final equals = line.indexOf('=');
      if (equals < 0) continue;
      if (line.substring(0, equals).trim().toLowerCase() != 'url') continue;
      final value = line.substring(equals + 1).trim();
      if (value.isEmpty) return const ReadFact.unknown();
      return _looksLikeUrl(value)
          ? ReadFact.known(value)
          : const ReadFact.unknown();
    }
    return sawSection ? const ReadFact.unknown() : const ReadFact.known(null);
  }

  /// `origin/HEAD` as this clone recorded it, from the ref file or from
  /// `packed-refs`.
  ///
  /// The loose ref is symbolic. A bare sha reads as **null**, which is what `git
  /// rev-parse` answers for it. A named line in `packed-refs` is unknown, since
  /// `git pack-refs` does not pack symbolic refs; neither file is unknown too,
  /// because the `reftable` backend keeps no `refs/` tree. A `packed-refs` that
  /// names no `origin/HEAD` *is* an answer.
  Future<ReadFact<String?>> _originHeadIn(
    String common,
    p.Context context,
  ) async {
    final loose = await files.readString(
      context.joinAll([common, 'refs', 'remotes', 'origin', 'HEAD']),
    );
    if (loose != null) {
      final line = loose.trim();
      if (!line.startsWith('ref:')) return const ReadFact.known(null);
      final target = line.substring('ref:'.length).trim();
      const prefix = 'refs/remotes/origin/';
      if (!target.startsWith(prefix) || target.length == prefix.length) {
        return const ReadFact.unknown();
      }
      return ReadFact.known('origin/${target.substring(prefix.length)}');
    }
    final packed = await files.readString(context.join(common, 'packed-refs'));
    if (packed == null) return const ReadFact.unknown();
    for (final raw in packed.split(RegExp(r'[\r\n]'))) {
      if (raw.trimRight().endsWith(' refs/remotes/origin/HEAD')) {
        return const ReadFact.unknown();
      }
    }
    return const ReadFact.known(null);
  }

  /// Whether [header] is the `origin` remote's section header, quoted or dotted.
  ///
  /// A section name is case-insensitive to git; a *subsection* is not, so
  /// `[remote "Origin"]` is a different remote and must not match.
  static bool _isOriginRemote(String header) {
    final quoted = RegExp(r'^(\S+)\s+"([^"]*)"$').firstMatch(header);
    if (quoted != null) {
      return quoted.group(1)!.toLowerCase() == 'remote' &&
          quoted.group(2) == 'origin';
    }
    // `[remote.origin]` is a plain section name, which git folds entirely.
    return header.toLowerCase() == 'remote.origin';
  }

  /// Whether [value] is spelled like a remote URL rather than like a local path
  /// or an `insteadOf` shorthand. See [_originUrlIn] for why the difference
  /// matters.
  static bool _looksLikeUrl(String value) {
    final scheme = RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*://').firstMatch(value);
    if (scheme != null) return true;
    // scp-like `[user@]host:path`, which needs a credible host. A Windows path
    // (`C:\src\app`) and a shorthand (`gh:acme/repo`) both have the colon and
    // neither has a dotted host or a user, which is exactly the distinction.
    final at = value.indexOf('@');
    final rest = at >= 0 ? value.substring(at + 1) : value;
    final colon = rest.indexOf(':');
    if (colon <= 0) return false;
    return at >= 0 || rest.substring(0, colon).contains('.');
  }

  /// `[include]`, `[includeIf "…"]` or `[url "…"]` — the three section headers
  /// that can make a correctly-read `remote.origin.url` the wrong answer.
  static final _indirection = RegExp(
    r'^\s*\[\s*(include(If)?|url)\b',
    multiLine: true,
    caseSensitive: false,
  );
}
