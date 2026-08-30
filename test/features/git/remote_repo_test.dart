import 'package:chitragupta/src/features/git/domain/remote_repo.dart';
import 'package:flutter_test/flutter_test.dart';

/// Turning an `origin` URL into a page a browser can open.
///
/// The forms below are all ones git itself accepts, and a user has at least one
/// of each: `git@` from an ssh clone, `https` from a browser copy, and a
/// self-hosted host from work.
void main() {
  group('parses the forms git accepts', () {
    test('scp-like ssh with a user', () {
      final repo = RemoteRepo.parse('git@github.com:popupbits/chitragupta.git');
      expect(repo?.host, 'github.com');
      expect(repo?.slug, 'popupbits/chitragupta');
      expect(repo?.owner, 'popupbits');
      expect(repo?.name, 'chitragupta');
    });

    test('scp-like without a user, when the host looks like one', () {
      expect(
        RemoteRepo.parse('github.com:owner/repo'),
        const RemoteRepo(host: 'github.com', slug: 'owner/repo'),
      );
    });

    test('https, with and without the .git suffix', () {
      const expected = RemoteRepo(host: 'github.com', slug: 'owner/repo');
      expect(RemoteRepo.parse('https://github.com/owner/repo.git'), expected);
      expect(RemoteRepo.parse('https://github.com/owner/repo'), expected);
      expect(RemoteRepo.parse('https://github.com/owner/repo/'), expected);
    });

    test('https with credentials in the URL drops them', () {
      expect(
        RemoteRepo.parse('https://token:x@github.com/owner/repo.git')?.webUrl,
        'https://github.com/owner/repo',
      );
    });

    test('ssh:// with a port serves the web over https without it', () {
      expect(
        RemoteRepo.parse(
          'ssh://git@git.corp.example:2222/team/app.git',
        )?.webUrl,
        'https://git.corp.example/team/app',
      );
    });

    test('an explicit http(s) port is kept — that one is the web port', () {
      expect(
        RemoteRepo.parse('https://git.corp.example:8443/team/app.git')?.host,
        'git.corp.example:8443',
      );
    });

    test('git:// and a nested group path', () {
      expect(
        RemoteRepo.parse('git://gitlab.com/group/sub/app.git')?.slug,
        'group/sub/app',
      );
    });

    test('the host is case-folded, the path is not', () {
      final repo = RemoteRepo.parse('git@GitHub.com:PopupBits/App.git');
      expect(repo?.host, 'github.com');
      expect(repo?.slug, 'PopupBits/App');
    });
  });

  group('refuses things that have no web page', () {
    for (final url in <String?>[
      null,
      '',
      '   ',
      r'C:\src\app',
      'C:/src/app',
      '/home/me/app',
      'file:///home/me/app',
      '../sibling',
      'https://github.com/owner',
    ]) {
      test('${url ?? 'null'} is not a remote repository', () {
        expect(RemoteRepo.parse(url), isNull);
      });
    }
  });

  group('builds the links the app needs', () {
    final repo = RemoteRepo.parse('git@github.com:owner/repo.git')!;

    test('commit', () {
      expect(
        repo.commitUrl('abc123'),
        'https://github.com/owner/repo/commit/abc123',
      );
    });

    test('pull request', () {
      expect(repo.pullRequestUrl(42), 'https://github.com/owner/repo/pull/42');
    });

    test('branch', () {
      expect(
        repo.branchUrl('feature/x'),
        'https://github.com/owner/repo/tree/feature/x',
      );
    });
  });
}
