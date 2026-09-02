import 'package:karmashala/src/features/terminal/domain/terminal_link_resolution.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_links.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';
import 'package:flutter_test/flutter_test.dart';

/// Turning a path printed in a pane into a path on this machine.
///
/// Pure: no filesystem, no database. Every case here is decided by the text
/// plus the pane's own two facts — the directory it opened in, and the shell it
/// runs.
void main() {
  String? resolve(
    String raw, {
    String? cwd,
    String profile = TerminalProfile.powerShellId,
    int? line,
  }) => hostPathForTerminalTarget(
    PathTarget(raw, line: line),
    workingDirectory: cwd,
    profileId: profile,
  );

  const wslProfile = 'wsl:Ubuntu';
  const wslCwd = r'\\wsl.localhost\Ubuntu\home\me\proj';

  group('already the host’s spelling', () {
    test('a drive path stands as it is', () {
      expect(resolve(r'C:\src\app\lib\main.dart'), r'C:\src\app\lib\main.dart');
    });

    test('forward slashes are normalised to the host’s', () {
      expect(resolve('C:/src/app/pubspec.yaml'), r'C:\src\app\pubspec.yaml');
    });

    test('a UNC path keeps both leading slashes', () {
      expect(resolve(wslCwd), wslCwd);
    });

    test('and it does not need a working directory', () {
      expect(resolve(r'C:\src\app', cwd: null), r'C:\src\app');
    });
  });

  group('an absolute POSIX path', () {
    test('in a WSL pane maps onto the distribution', () {
      expect(
        resolve('/home/me/proj/lib/main.dart', profile: wslProfile),
        r'\\wsl.localhost\Ubuntu\home\me\proj\lib\main.dart',
      );
    });

    test('under /mnt is the Windows drive it is mounted from', () {
      expect(
        resolve('/mnt/c/src/app/main.dart', profile: wslProfile),
        r'C:\src\app\main.dart',
      );
    });

    test('in a PowerShell pane resolves to nothing', () {
      // Nothing here knows which machine `/home/me` was talking about, and
      // guessing is the implicit conversion `EnvironmentPath` exists to forbid.
      expect(resolve('/home/me/x', cwd: r'C:\src\app'), isNull);
    });

    test('is left alone when the pane itself is on a POSIX host', () {
      // The pane's own directory is the honest evidence for which host this is.
      expect(resolve('/home/me/x', cwd: '/home/me/proj'), '/home/me/x');
    });
  });

  group('a relative path', () {
    test('resolves against the pane’s working directory', () {
      expect(
        resolve('lib/main.dart', cwd: r'C:\src\app'),
        r'C:\src\app\lib\main.dart',
      );
    });

    test('and against a UNC one, which is what a WSL pane has', () {
      expect(
        resolve('lib/main.dart', cwd: wslCwd, profile: wslProfile),
        r'\\wsl.localhost\Ubuntu\home\me\proj\lib\main.dart',
      );
    });

    test('a leading ./ is dropped and ../ walks up', () {
      expect(
        resolve('./lib/main.dart', cwd: r'C:\src\app'),
        r'C:\src\app\lib\main.dart',
      );
      expect(
        resolve('../other/x.txt', cwd: r'C:\src\app'),
        r'C:\src\other\x.txt',
      );
    });

    test('and against a POSIX one, which is what a WSL pane usually has', () {
      // The reported bug: "terminal absolute file path working but not relative
      // path". A WSL pane's working directory is its own spelling — `/mnt/c/…`
      // or `/home/…` — and joining onto it produced a WSL path that was then
      // handed to a Windows `stat`, which of course found nothing. An absolute
      // POSIX path was translated; a relative one has to be too, once its
      // directory is in front of it.
      expect(
        resolve('lib/main.dart', cwd: '/mnt/c/src/app', profile: wslProfile),
        r'C:\src\app\lib\main.dart',
      );
      expect(
        resolve('lib/main.dart', cwd: '/home/me/proj', profile: wslProfile),
        r'\\wsl.localhost\Ubuntu\home\me\proj\lib\main.dart',
      );
    });

    test('spelled with backslashes, as a Windows tool prints it', () {
      // Filed as a bug — the POSIX join does leave the backslashes as ordinary
      // filename characters — and it is not one: the WSL→Windows translation
      // rewrites `/` to `\` and leaves `\` alone, so the spelling a Windows
      // tool prints from a WSL pane arrives at the same place a POSIX one
      // does. Pinned here so the join is never "fixed" into a second reading
      // that buys nothing.
      expect(
        resolve(
          r'windows\installer\out\x.exe',
          cwd: '/mnt/c/src/app',
          profile: wslProfile,
        ),
        r'C:\src\app\windows\installer\out\x.exe',
      );
      expect(
        resolve(
          r'build\out\log.txt',
          cwd: '/home/me/proj',
          profile: wslProfile,
        ),
        r'\\wsl.localhost\Ubuntu\home\me\proj\build\out\log.txt',
      );
    });

    test('joins in the flavour of the directory it is joined to', () {
      expect(
        resolve('lib/main.dart', cwd: '/home/me/proj'),
        '/home/me/proj/lib/main.dart',
      );
    });

    test('resolves to nothing when the pane has no directory', () {
      expect(resolve('lib/main.dart', cwd: null), isNull);
    });
  });

  group('what stays unresolved', () {
    test('a home-relative path', () {
      // The home directory belongs to whichever user the program ran as, and
      // the pane never learns it. Detected, so a later loop can honour it;
      // resolved to nothing, so nothing is opened on a guess.
      expect(resolve('~/notes/x.md', cwd: r'C:\src\app'), isNull);
    });

    test('an empty path', () {
      expect(resolve('', cwd: r'C:\src\app'), isNull);
    });

    test('a POSIX path in a WSL pane whose distro is gone from the id', () {
      expect(resolve('/home/me/x', profile: 'wsl:'), isNull);
    });
  });

  test('the location rides along and does not change the path', () {
    expect(
      resolve('lib/main.dart', cwd: r'C:\src\app', line: 42),
      r'C:\src\app\lib\main.dart',
    );
  });
}
