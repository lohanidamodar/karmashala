import 'package:karmashala_git/git.dart';
import 'package:test/test.dart';

/// **What `.git` can be trusted to say, and what has to be handed back to git.**
///
/// `git remote get-url origin` and `git rev-parse --abbrev-ref origin/HEAD` are
/// two subprocesses answering two single lines of text, and on Windows a
/// subprocess is never free however it is awaited — `CreateProcessW` runs on
/// the calling thread before the future exists. So a delivery row reads the
/// two lines instead.
///
/// The whole risk of that trade is a **confident wrong answer**: the URL
/// decides whether a row looks for a pull request and what its commit links
/// point at, and `origin/HEAD` is the base every ahead/behind count is measured
/// against. So every case below is really the same question asked twice — is
/// this an answer, or is it an admission — and the cases that end in
/// `known: false` are as load-bearing as the ones that parse.
void main() {
  const repo = r'C:\src\app';
  const wt = r'C:\src\.karmashala-worktrees\wt-1';

  const originConfig =
      '[core]\n'
      '\tbare = false\n'
      '[remote "origin"]\n'
      '\turl = https://github.com/acme/app.git\n'
      '\tfetch = +refs/heads/*:refs/remotes/origin/*\n'
      '[branch "main"]\n'
      '\tremote = origin\n';

  GitOriginReader readerOver(
    Map<String, String> disk, {
    bool reachable = true,
  }) => GitOriginReader(
    files: _MapFiles(disk),
    hostPathOf: reachable ? (path) => path : (_) => null,
  );

  group('an ordinary checkout', () {
    test('reads both facts, and reads exactly two files', () async {
      final files = _MapFiles({
        r'C:\src\app\.git\config': originConfig,
        r'C:\src\app\.git\refs\remotes\origin\HEAD':
            'ref: refs/remotes/origin/main\n',
      });
      final reading = await GitOriginReader(
        files: files,
        hostPathOf: (path) => path,
      ).read(repo);

      expect(reading.url.known, isTrue);
      expect(reading.url.value, 'https://github.com/acme/app.git');
      expect(reading.head.known, isTrue);
      expect(reading.head.value, 'origin/main');
      // The point of the exercise: two reads, no `stat` in front of either.
      // Asking *whether* a file exists costs the same as reading it on a
      // `\\wsl.localhost` share, so the reader does not ask.
      expect(files.reads, [
        r'C:\src\app\.git\config',
        r'C:\src\app\.git\refs\remotes\origin\HEAD',
      ]);
    });

    test('a POSIX host path joins the POSIX way', () async {
      final reading = await readerOver({
        '/home/me/app/.git/config': originConfig,
        '/home/me/app/.git/refs/remotes/origin/HEAD':
            'ref: refs/remotes/origin/trunk\n',
      }).read('/home/me/app');
      expect(reading.url.value, 'https://github.com/acme/app.git');
      expect(reading.head.value, 'origin/trunk');
    });

    test('a WSL checkout is read over its UNC share', () async {
      // The trap `storePathContextFor` documents, in this reader's words: a
      // path *inside* WSL is POSIX, but the spelling this process can open is
      // the `\\wsl.localhost\…` UNC form, which is a Windows path. Joining the
      // UNC form the POSIX way would build something no `File` can open.
      final reading = await GitOriginReader(
        files: _MapFiles({
          r'\\wsl.localhost\arch\home\me\app\.git\config': originConfig,
          r'\\wsl.localhost\arch\home\me\app\.git\refs\remotes\origin\HEAD':
              'ref: refs/remotes/origin/main\n',
        }),
        hostPathOf: (path) =>
            r'\\wsl.localhost\arch' + path.replaceAll('/', r'\'),
      ).read('/home/me/app');
      expect(reading.url.value, 'https://github.com/acme/app.git');
      expect(reading.head.value, 'origin/main');
    });
  });

  group("a working tree whose `.git` is a file", () {
    test('follows the pointer and shares the clone answer', () async {
      // What git writes for a worktree. The config and the remote refs live in
      // the clone's git directory, one level above `worktrees/<name>`, which is
      // exactly why two worktrees of one clone have one answer.
      final files = _MapFiles({
        wt + r'\.git': 'gitdir: C:\\src\\app\\.git\\worktrees\\wt-1\n',
        r'C:\src\app\.git\config': originConfig,
        r'C:\src\app\.git\refs\remotes\origin\HEAD':
            'ref: refs/remotes/origin/main\n',
      });
      final reading = await GitOriginReader(
        files: files,
        hostPathOf: (path) => path,
      ).read(wt);

      expect(reading.url.value, 'https://github.com/acme/app.git');
      expect(reading.head.value, 'origin/main');
      // Four reads, and the first one is the failed `<worktree>/.git/config`
      // that told it this was not an ordinary checkout.
      expect(files.reads.first, wt + r'\.git\config');
      expect(files.reads.length, 4);
    });

    test('a relative gitdir resolves against the working tree', () async {
      // What `git worktree --relative-paths` writes since 2.48.
      final reading = await readerOver({
        wt + r'\.git': 'gitdir: ../../app/.git/worktrees/wt-1\n',
        r'C:\src\app\.git\config': originConfig,
        r'C:\src\app\.git\refs\remotes\origin\HEAD':
            'ref: refs/remotes/origin/main\n',
      }).read(wt);
      expect(reading.url.value, 'https://github.com/acme/app.git');
      expect(reading.head.value, 'origin/main');
    });

    test('a submodule gitdir is its own repository', () async {
      // `<super>/.git/modules/<name>` is the submodule's *own* git directory,
      // not a worktree of the superproject, so nothing is stripped from it —
      // and its remote is its own, which is the whole reason it matters.
      final reading = await readerOver({
        r'C:\src\app\vendor\lib\.git':
            'gitdir: C:\\src\\app\\.git\\modules\\lib\n',
        r'C:\src\app\.git\modules\lib\config':
            '[remote "origin"]\n\turl = https://github.com/acme/lib.git\n',
        r'C:\src\app\.git\modules\lib\refs\remotes\origin\HEAD':
            'ref: refs/remotes/origin/release\n',
      }).read(r'C:\src\app\vendor\lib');
      expect(reading.url.value, 'https://github.com/acme/lib.git');
      expect(reading.head.value, 'origin/release');
    });

    test('a `.git` file that is not a pointer is unknown', () async {
      final reading = await readerOver({
        wt + r'\.git': 'this is not a git directory pointer\n',
      }).read(wt);
      expect(reading.url.known, isFalse);
      expect(reading.head.known, isFalse);
    });
  });

  group('the URL', () {
    Future<ReadFact<String?>> urlFrom(String config) async =>
        (await readerOver({
          r'C:\src\app\.git\config': config,
          r'C:\src\app\.git\refs\remotes\origin\HEAD':
              'ref: refs/remotes/origin/main\n',
        }).read(repo)).url;

    test('no `origin` section at all is a confident "no remote"', () async {
      final url = await urlFrom('[core]\n\tbare = false\n');
      expect(url.known, isTrue);
      expect(url.value, isNull);
    });

    test('an `origin` section with no url is unknown', () async {
      // Not a shape git writes. Something else is setting the URL and only git
      // can see it.
      final url = await urlFrom('[remote "origin"]\n\tfetch = +refs/*:refs/*\n');
      expect(url.known, isFalse);
    });

    test('an scp-like remote reads', () async {
      final url = await urlFrom(
        '[remote "origin"]\n\turl = git@github.com:acme/app.git\n',
      );
      expect(url.value, 'git@github.com:acme/app.git');
    });

    test('a subsection and its key on one line reads', () async {
      // Legal git config, and a shape `git clone` never writes — so it is
      // exactly the kind of thing a hand-edited config carries.
      final url = await urlFrom(
        '[remote "origin"] url = https://example.com/a/b.git\n',
      );
      expect(url.value, 'https://example.com/a/b.git');
    });

    test('a different remote spelled `Origin` is not `origin`', () async {
      // A section name is case-insensitive to git; a subsection is not.
      final url = await urlFrom(
        '[remote "Origin"]\n\turl = https://github.com/acme/other.git\n',
      );
      expect(url.known, isTrue);
      expect(url.value, isNull);
    });

    test('an `include` makes the whole file untrustworthy', () async {
      // The remote may be defined in a file this reader does not open.
      final url = await urlFrom(
        '[include]\n\tpath = ../shared.config\n'
        '[remote "origin"]\n\turl = https://github.com/acme/app.git\n',
      );
      expect(url.known, isFalse);
    });

    test('an `includeIf` does too', () async {
      final url = await urlFrom(
        '[includeIf "gitdir:~/work/"]\n\tpath = work.config\n'
        '[remote "origin"]\n\turl = https://github.com/acme/app.git\n',
      );
      expect(url.known, isFalse);
    });

    test('a `url` section is where insteadOf lives, so unknown', () async {
      // `git remote get-url` expands `url.<base>.insteadOf`; a read cannot.
      final url = await urlFrom(
        '[url "https://github.com/"]\n\tinsteadOf = gh:\n'
        '[remote "origin"]\n\turl = gh:acme/app.git\n',
      );
      expect(url.known, isFalse);
    });

    test('a remote that does not look like a URL is unknown', () async {
      // The catch-all for an `insteadOf` in the user's *global* config, which
      // is invisible from here: a shorthand is by construction not URL-shaped.
      // A local-path remote lands here too and pays one process, which is the
      // right way round — only git can tell the two apart.
      expect((await urlFrom('[remote "origin"]\n\turl = gh:acme/app\n')).known,
          isFalse);
      expect(
        (await urlFrom('[remote "origin"]\n\turl = ../sibling-clone\n')).known,
        isFalse,
      );
      expect(
        (await urlFrom('[remote "origin"]\n\turl = C:\\src\\other\n')).known,
        isFalse,
      );
    });

    test('an unreadable URL makes the head unknown too', () async {
      // The one genuinely wrong answer available here: the caller would ask
      // git for the URL, get one, and then take this reader's word that the
      // clone records no default branch.
      final reading = await readerOver({
        r'C:\src\app\.git\config': '[include]\n\tpath = x\n',
        r'C:\src\app\.git\refs\remotes\origin\HEAD':
            'ref: refs/remotes/origin/main\n',
      }).read(repo);
      expect(reading.url.known, isFalse);
      expect(reading.head.known, isFalse);
    });

    test('no remote means no head to look for, and no read for it', () async {
      final files = _MapFiles({
        r'C:\src\app\.git\config': '[core]\n\tbare = false\n',
      });
      final reading = await GitOriginReader(
        files: files,
        hostPathOf: (path) => path,
      ).read(repo);
      expect(reading.head.known, isTrue);
      expect(reading.head.value, isNull);
      expect(files.reads, [r'C:\src\app\.git\config']);
    });
  });

  group('`origin/HEAD`', () {
    Future<ReadFact<String?>> headFrom(Map<String, String> disk) async =>
        (await readerOver({
          r'C:\src\app\.git\config': originConfig,
          ...disk,
        }).read(repo)).head;

    test('a symbolic ref names the branch', () async {
      final head = await headFrom({
        r'C:\src\app\.git\refs\remotes\origin\HEAD':
            'ref: refs/remotes/origin/develop\n',
      });
      expect(head.value, 'origin/develop');
    });

    test('a bare sha is "none recorded", the same as git says', () async {
      // `git rev-parse --abbrev-ref origin/HEAD` answers `origin/HEAD` for a
      // non-symbolic ref, which the git path already reads as null.
      final head = await headFrom({
        r'C:\src\app\.git\refs\remotes\origin\HEAD':
            '9f1c0d2e5b4a37860f1d2c3b4a5968770e1f2d3c\n',
      });
      expect(head.known, isTrue);
      expect(head.value, isNull);
    });

    test('a ref pointing somewhere unexpected is unknown', () async {
      final head = await headFrom({
        r'C:\src\app\.git\refs\remotes\origin\HEAD': 'ref: refs/heads/main\n',
      });
      expect(head.known, isFalse);
    });

    test('packed-refs with no origin/HEAD is "none recorded"', () async {
      // The single-branch clone, and the common case for a repository someone
      // ran `git remote add` on years ago.
      final head = await headFrom({
        r'C:\src\app\.git\packed-refs':
            '# pack-refs with: peeled fully-peeled sorted \n'
            '9f1c0d2e5b4a37860f1d2c3b4a5968770e1f2d3c refs/remotes/origin/main\n',
      });
      expect(head.known, isTrue);
      expect(head.value, isNull);
    });

    test('packed-refs naming origin/HEAD is unknown, not null', () async {
      // `git pack-refs` does not pack symbolic refs, so a line naming
      // `origin/HEAD` is a shape this parse does not understand — and guessing
      // null would be guessing.
      final head = await headFrom({
        r'C:\src\app\.git\packed-refs':
            '9f1c0d2e5b4a37860f1d2c3b4a5968770e1f2d3c refs/remotes/origin/HEAD\n',
      });
      expect(head.known, isFalse);
    });

    test('neither file is unknown, because reftable exists', () async {
      // Git's `reftable` backend keeps no `refs/` tree and no `packed-refs`.
      // "I found nothing" there would be a wrong answer rather than an absence.
      final head = await headFrom(const {});
      expect(head.known, isFalse);
    });
  });

  group('nothing readable', () {
    test('a directory that is not a repository is unknown', () async {
      final reading = await readerOver(const {}).read(r'C:\src\not-a-repo');
      expect(reading.url.known, isFalse);
      expect(reading.head.known, isFalse);
    });

    test('a filesystem this process cannot open is unknown', () async {
      // An SSH repository. There is no local path for it, so the answer is
      // "ask git over the transport" rather than an error.
      final files = _MapFiles({r'C:\src\app\.git\config': originConfig});
      final reading = await GitOriginReader(
        files: files,
        hostPathOf: (_) => null,
      ).read(repo);
      expect(reading.url.known, isFalse);
      expect(reading.head.known, isFalse);
      expect(files.reads, isEmpty, reason: 'nothing local was even tried');
    });
  });
}

/// [GitFiles] over a map, recording every path read.
///
/// A missing key is a null read, which is what the real one answers for an
/// absent file, an unreadable one **and a directory** — see
/// [GitFiles.readString] for why those are deliberately one answer.
class _MapFiles implements GitFiles {
  _MapFiles(this.contents);

  final Map<String, String> contents;
  final List<String> reads = [];

  @override
  Future<String?> readString(String path) async {
    reads.add(path);
    return contents[path];
  }

  @override
  Future<bool> exists(String path) async =>
      throw UnimplementedError('this reader never stats');

  @override
  Future<PathEntry> typeOf(String path) async =>
      throw UnimplementedError('this reader never stats');

  @override
  Future<void> createDirectory(String path) async =>
      throw UnimplementedError('this reader never writes');

  @override
  Future<void> writeString(String path, String contents) async =>
      throw UnimplementedError('this reader never writes');
}
