import 'package:karmashala/src/features/browser/data/chrome_discovery.dart';
import 'package:karmashala/src/features/browser/domain/browser_failure.dart';
import 'package:flutter_test/flutter_test.dart';

const _windowsEnv = {
  'LOCALAPPDATA': r'C:\Users\dev\AppData\Local',
  'PROGRAMFILES': r'C:\Program Files',
  'PROGRAMFILES(X86)': r'C:\Program Files (x86)',
};

void main() {
  group('chromeCandidatePaths', () {
    test('an explicit CHROME_EXECUTABLE wins over everything', () {
      final candidates = chromeCandidatePaths(
        host: HostKind.windows,
        env: {..._windowsEnv, 'CHROME_EXECUTABLE': r'D:\chrome\chrome.exe'},
      );
      expect(candidates.first, r'D:\chrome\chrome.exe');
    });

    test('CHROME_PATH is honoured after CHROME_EXECUTABLE', () {
      final candidates = chromeCandidatePaths(
        host: HostKind.windows,
        env: {'CHROME_EXECUTABLE': r'D:\a.exe', 'CHROME_PATH': r'D:\b.exe'},
      );
      expect(candidates.take(2), [r'D:\a.exe', r'D:\b.exe']);
    });

    test('Windows looks in the three usual install roots', () {
      final candidates = chromeCandidatePaths(
        host: HostKind.windows,
        env: _windowsEnv,
      );
      expect(candidates, [
        r'C:\Users\dev\AppData\Local\Google\Chrome\Application\chrome.exe',
        r'C:\Program Files\Google\Chrome\Application\chrome.exe',
        r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
        r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
        r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
        r'C:\Users\dev\AppData\Local\Microsoft\Edge\Application\msedge.exe',
      ]);
    });

    test('Chrome is always preferred to Edge', () {
      final candidates = chromeCandidatePaths(
        host: HostKind.windows,
        env: _windowsEnv,
      );
      final lastChrome = candidates.lastIndexWhere((p) => p.contains('Chrome'));
      final firstEdge = candidates.indexWhere((p) => p.contains('Edge'));
      expect(lastChrome, lessThan(firstEdge));
    });

    test('blank environment variables are skipped, not turned into paths', () {
      final candidates = chromeCandidatePaths(
        host: HostKind.windows,
        env: const {
          'CHROME_EXECUTABLE': '  ',
          'PROGRAMFILES': r'C:\Program Files',
        },
      );
      expect(candidates, [
        r'C:\Program Files\Google\Chrome\Application\chrome.exe',
        r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
      ]);
    });

    test('duplicates collapse', () {
      final candidates = chromeCandidatePaths(
        host: HostKind.windows,
        env: const {
          'PROGRAMFILES': r'C:\Program Files',
          'PROGRAMFILES(X86)': r'C:\Program Files',
        },
      );
      expect(candidates.where((p) => p.contains('chrome.exe')).length, 1);
    });

    test('macOS looks in /Applications and the user Applications folder', () {
      final candidates = chromeCandidatePaths(
        host: HostKind.macos,
        env: const {'HOME': '/Users/dev'},
      );
      expect(candidates.first, contains('/Applications/Google Chrome.app'));
      expect(candidates, contains(startsWith('/Users/dev/Applications')));
    });

    test('Linux covers chrome, chromium and the snap', () {
      final candidates = chromeCandidatePaths(
        host: HostKind.linux,
        env: const {},
      );
      expect(candidates, contains('/usr/bin/google-chrome'));
      expect(candidates, contains('/usr/bin/chromium-browser'));
      expect(candidates, contains('/snap/bin/chromium'));
    });
  });

  group('findChromeExecutable', () {
    test('returns the first candidate that is actually there', () {
      final found = findChromeExecutable(
        host: HostKind.windows,
        env: _windowsEnv,
        exists: (path) => path.startsWith(r'C:\Program Files\Google'),
      );
      expect(found, r'C:\Program Files\Google\Chrome\Application\chrome.exe');
    });

    test('returns null when nothing is installed', () {
      expect(
        findChromeExecutable(
          host: HostKind.windows,
          env: _windowsEnv,
          exists: (_) => false,
        ),
        isNull,
      );
    });

    test('falls through to Edge when Chrome is absent', () {
      final found = findChromeExecutable(
        host: HostKind.windows,
        env: _windowsEnv,
        exists: (path) => path.contains('msedge.exe'),
      );
      expect(found, contains('msedge.exe'));
    });
  });

  group('chromeLaunchArguments', () {
    test('always opens the debugging port on a throwaway profile', () {
      final args = chromeLaunchArguments(
        port: 9333,
        userDataDir: r'C:\Temp\karmashala-cdp-profile-1',
      );
      expect(args, contains('--remote-debugging-port=9333'));
      expect(
        args,
        contains(r'--user-data-dir=C:\Temp\karmashala-cdp-profile-1'),
      );
      expect(args, contains('--no-first-run'));
      expect(args, contains('--no-default-browser-check'));
    });

    test('the url goes last, defaulting to about:blank', () {
      expect(
        chromeLaunchArguments(port: 1, userDataDir: 'd').last,
        'about:blank',
      );
      expect(
        chromeLaunchArguments(
          port: 1,
          userDataDir: 'd',
          initialUrl: 'https://example.com',
        ).last,
        'https://example.com',
      );
      expect(
        chromeLaunchArguments(port: 1, userDataDir: 'd', initialUrl: '').last,
        'about:blank',
      );
    });

    test('never passes a headless or profile-sharing flag', () {
      final args = chromeLaunchArguments(port: 1, userDataDir: 'd');
      expect(args, isNot(contains(startsWith('--headless'))));
      expect(args.where((a) => a.startsWith('--user-data-dir')), hasLength(1));
    });
  });

  test('throwChromeNotFound raises the standard failure', () {
    expect(
      throwChromeNotFound,
      throwsA(
        isA<BrowserException>().having(
          (e) => e.failure,
          'failure',
          BrowserFailure.chromeNotFound,
        ),
      ),
    );
  });
}
