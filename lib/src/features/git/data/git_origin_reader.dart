import 'package:path/path.dart' as p;

import 'git_dir.dart';
import 'git_files.dart';

/// One fact read off disk, or the admission that the files could not answer it.
///
/// [known] is the whole type. `null` on its own cannot carry the difference
/// between *"this clone has no `origin`"* and *"these bytes did not tell me"*,
/// and the two need opposite responses: the first is an answer, the second is a
/// reason to spend a process. Collapsing them is how a reader like this turns a
/// slow app into a wrong one — the same rule §19 states for the health panel,
/// applied to a file instead of a probe.
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
/// **Why this exists.** `git remote get-url origin` and `git rev-parse
/// --abbrev-ref origin/HEAD` are two subprocesses answering two single lines of
/// text. On Windows a subprocess is never free however it is awaited —
/// `CreateProcessW` runs on the *calling thread* before the future exists,
/// which is why a profile of this app named `RtlCreateUnicodeString` and
/// `NtCreateUserProcess` among its top Dart CPU leaves — and for a repository
/// inside WSL each one also crosses the 9p boundary. Two reads of two files
/// cost no `CreateProcessW` at all. They are still 9p reads for a WSL
/// checkout: cheaper than a process, not free.
///
/// **Every uncertainty is a [ReadFact.unknown], and the caller then asks git.**
/// A wrong answer here is worse than a slow one: the URL decides whether a row
/// looks for a pull request and what its commit links point at, and
/// `origin/HEAD` is the base every `ahead/behind` count is measured against.
/// The guards below are all of that shape.
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
  /// Costs **two reads** for an ordinary checkout — `.git/config` and
  /// `.git/refs/remotes/origin/HEAD` — and up to four for a working tree whose
  /// `.git` is a *file* naming the real git directory, which is what git writes
  /// for a worktree and for a submodule.
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

    // The ordinary case first and with no `stat` in front of it: `.git` is a
    // directory, so `.git/config` is simply there. A failed read is how this
    // learns otherwise, because on a `\\wsl.localhost` share asking *whether*
    // a file exists costs the same as reading it.
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
    // An unreadable URL hands the **whole** reading to git. Reporting a known
    // `origin/HEAD` beside an unknown URL would be the one genuinely wrong
    // answer available here: the caller would ask git for the URL, get one,
    // and then take this reader's word that there is no default branch.
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

  /// The git directory two worktrees of one clone **share**.
  ///
  /// A worktree's own git directory is `<common>/worktrees/<name>`; the config
  /// and the remote refs live one level up from that pair. Anything else —
  /// a submodule's `<super>/.git/modules/<name>`, a bare `GIT_DIR` — is
  /// already its own common directory and is left alone.
  String _commonDirOf(String gitDir, p.Context context) {
    final parts = gitDir.split(RegExp(r'[\\/]'));
    if (parts.length < 2) return gitDir;
    if (parts[parts.length - 2] != 'worktrees') return gitDir;
    return parts.sublist(0, parts.length - 2).join(context.separator);
  }

  /// `remote.origin.url` as `.git/config` records it.
  ///
  /// Unknown — ask git — in three cases, each of which is a way for the file to
  /// be true and the answer still wrong:
  ///
  /// * **An `[include]` or `[includeIf …]` section.** The remote may be defined
  ///   in a file this does not open.
  /// * **A `[url "…"]` section**, which is where `insteadOf` rewriting lives.
  ///   `git remote get-url` expands those; a read cannot.
  /// * **A URL that does not look like a URL.** That is either a local path or
  ///   an `insteadOf` shorthand — the point of a shorthand being that it is
  ///   short — and only git can tell them apart. This is also the guard that
  ///   covers an `insteadOf` in the user's *global* config, which is invisible
  ///   from here: the shorthand it rewrites is by construction not URL-shaped.
  ///
  /// A config with no `[remote "origin"]` at all is a confident **null**: a
  /// `git init` with no remote, which is an ordinary row with nothing to say.
  /// A section that exists but carries no `url` is unknown, because that is not
  /// a shape git writes and something else is going on.
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
  /// The loose ref is a symbolic ref — `ref: refs/remotes/origin/main` — and is
  /// what a normal `git clone` writes. Three other shapes:
  ///
  /// * **A bare sha** in that file. `git rev-parse --abbrev-ref origin/HEAD`
  ///   then answers `origin/HEAD`, which the git path already reads as "no
  ///   default branch recorded", so this answers the same **null**.
  /// * **A named line in `packed-refs`.** Deliberately unknown: `git pack-refs`
  ///   does not pack symbolic refs, so a line naming `origin/HEAD` is
  ///   something this parse does not understand, and guessing null would be
  ///   guessing.
  /// * **Neither file.** Also unknown, and this is the case that matters most:
  ///   git's `reftable` backend keeps no `refs/` tree and no `packed-refs`, so
  ///   "I found nothing" there would be a wrong answer rather than an absence.
  ///
  /// A `packed-refs` that exists and names no `origin/HEAD` **is** an answer:
  /// this clone records no default branch, which is what a single-branch clone
  /// and an older `git remote add` both produce.
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

  /// Whether [header] is the `origin` remote's section header, in either of the
  /// two spellings git's own parser accepts for a subsection: the quoted form
  /// `remote "origin"` that `git clone` writes, and the dotted `remote.origin`.
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

  /// Whether [path] is absolute **in its own environment's spelling** — a POSIX
  /// root, a Windows drive, or a UNC root. Asked of a `gitdir:` line, which is
  /// written by git in that environment and not by this process.
  /// `[include]`, `[includeIf "…"]` or `[url "…"]` — the three section headers
  /// that can make a correctly-read `remote.origin.url` the wrong answer.
  static final _indirection = RegExp(
    r'^\s*\[\s*(include(If)?|url)\b',
    multiLine: true,
    caseSensitive: false,
  );
}
