import 'package:karmashala_git/git.dart';
import 'package:test/test.dart';

/// A disk that is a map, and counts what it was asked for. Everything but
/// [readString] throws: a branch name costs file reads and nothing else.
class _Files implements GitFiles {
  _Files(this.contents);

  final Map<String, String> contents;
  final reads = <String>[];

  @override
  Future<String?> readString(String path) async {
    reads.add(path);
    return contents[path];
  }

  @override
  Future<bool> exists(String path) => throw UnsupportedError('exists');

  @override
  Future<PathEntry> typeOf(String path) => throw UnsupportedError('stat');

  @override
  Future<void> createDirectory(String path) => throw UnsupportedError('mkdir');

  @override
  Future<void> writeString(String path, String contents) =>
      throw UnsupportedError('write');
}

void main() {
  group('gitHeadLabel', () {
    test('a branch is its name, slashes and all', () {
      expect(gitHeadLabel('ref: refs/heads/main\n'), 'main');
      expect(
        gitHeadLabel('ref: refs/heads/feature/explorer-polish\r\n'),
        'feature/explorer-polish',
      );
      expect(gitHeadLabel('ref:refs/heads/tight'), 'tight');
    });

    test('a detached HEAD is its short sha', () {
      expect(
        gitHeadLabel('9f21420b8c1d4e5f60718293a4b5c6d7e8f90123\n'),
        '9f21420',
      );
      // SHA-256 repositories write 64 digits.
      expect(gitHeadLabel('${'ab' * 32}\n'), 'abababa');
    });

    test('a ref outside refs/heads keeps enough to be told from a branch', () {
      expect(
        gitHeadLabel('ref: refs/remotes/origin/main'),
        'remotes/origin/main',
      );
    });

    test('nothing, or anything else, is no answer', () {
      for (final text in [
        null,
        '',
        '\n\n',
        'ref:',
        'ref: ',
        'ref: refs/heads/',
        'gitdir: ../elsewhere',
        'not a sha',
        '9f21420', // too short to be what git writes
        'zz21420b8c1d4e5f60718293a4b5c6d7e8f90123',
        '<<<<<<< HEAD',
      ]) {
        expect(gitHeadLabel(text), isNull, reason: '$text');
      }
    });
  });

  group('GitHeadReader', () {
    test('an ordinary clone is one file read, and no stat', () async {
      final files = _Files({'/w/app/.git/HEAD': 'ref: refs/heads/main\n'});
      expect(await GitHeadReader(files: files).read('/w/app'), 'main');
      expect(files.reads, ['/w/app/.git/HEAD']);
    });

    test('a worktree\'s .git is a file naming its git directory', () async {
      final files = _Files({
        '/w/app-polish/.git': 'gitdir: /w/app/.git/worktrees/app-polish\n',
        '/w/app/.git/worktrees/app-polish/HEAD': 'ref: refs/heads/ui/polish\n',
      });
      expect(
        await GitHeadReader(files: files).read('/w/app-polish'),
        'ui/polish',
      );
      expect(files.reads, [
        '/w/app-polish/.git/HEAD',
        '/w/app-polish/.git',
        '/w/app/.git/worktrees/app-polish/HEAD',
      ]);
    });

    test('a relative gitdir is resolved against the working tree', () async {
      final files = _Files({
        '/w/hub/modules/ui/.git': 'gitdir: ../../.git/modules/ui\n',
        '/w/hub/.git/modules/ui/HEAD':
            '1234567890abcdef1234567890abcdef12345678\n',
      });
      expect(
        await GitHeadReader(files: files).read('/w/hub/modules/ui'),
        '1234567',
      );
    });

    test('a Windows clone is joined the Windows way', () async {
      final files = _Files({
        r'C:\src\app\.git': r'gitdir: C:/src/main/.git/worktrees/app',
        r'C:\src\main\.git\worktrees\app\HEAD': 'ref: refs/heads/win\n',
      });
      expect(await GitHeadReader(files: files).read(r'C:\src\app'), 'win');
    });

    test(
      'a folder that is not a repository is no answer, in two reads',
      () async {
        final files = _Files({});
        expect(await GitHeadReader(files: files).read('/w/notes'), isNull);
        expect(files.reads, ['/w/notes/.git/HEAD', '/w/notes/.git']);
      },
    );

    test('garbage in either file is no answer', () async {
      final reader = GitHeadReader(
        files: _Files({
          '/a/.git/HEAD': '\u0000\u0001',
          '/b/.git': 'gitdir:',
          '/c/.git': 'gitdir: /gone',
        }),
      );
      expect(await reader.read('/a'), isNull);
      expect(await reader.read('/b'), isNull);
      expect(await reader.read('/c'), isNull);
    });
  });

  group('GitHeadCache', () {
    test('a root is read once while its stamp stands', () async {
      final files = _Files({'/w/app/.git/HEAD': 'ref: refs/heads/main\n'});
      final cache = GitHeadCache(GitHeadReader(files: files));

      expect(await cache.read('/w/app', stamp: 1), 'main');
      expect(await cache.read('/w/app', stamp: 1), 'main');
      expect(files.reads, hasLength(1));
    });

    test('two askers in one moment share one read', () async {
      final files = _Files({'/w/app/.git/HEAD': 'ref: refs/heads/main\n'});
      final cache = GitHeadCache(GitHeadReader(files: files));

      final answers = await Future.wait([
        cache.read('/w/app', stamp: 1),
        cache.read('/w/app', stamp: 1),
      ]);
      expect(answers, ['main', 'main']);
      expect(files.reads, hasLength(1));
    });

    test('a new stamp reads again, and only that root', () async {
      final files = _Files({
        '/w/app/.git/HEAD': 'ref: refs/heads/main\n',
        '/w/lib/.git/HEAD': 'ref: refs/heads/dev\n',
      });
      final cache = GitHeadCache(GitHeadReader(files: files));
      await cache.read('/w/app', stamp: 1);
      await cache.read('/w/lib', stamp: 1);
      files.reads.clear();

      files.contents['/w/app/.git/HEAD'] = 'ref: refs/heads/feature\n';
      expect(await cache.read('/w/app', stamp: 2), 'feature');
      expect(await cache.read('/w/lib', stamp: 1), 'dev');
      expect(files.reads, ['/w/app/.git/HEAD']);
    });

    test('it is bounded', () async {
      final files = _Files({});
      final cache = GitHeadCache(GitHeadReader(files: files), capacity: 8);
      for (var i = 0; i < 100; i++) {
        await cache.read('/w/$i', stamp: 0);
      }
      expect(cache.length, lessThanOrEqualTo(8));
    });
  });
}
