import 'dart:io';

import '../domain/browser_failure.dart';

/// Host operating system, as far as browser locations are concerned.
enum HostKind { windows, macos, linux }

/// The host we are running on.
HostKind currentHostKind() {
  if (Platform.isWindows) return HostKind.windows;
  if (Platform.isMacOS) return HostKind.macos;
  return HostKind.linux;
}

/// Ordered candidate paths for a Chromium-family browser.
///
/// `CHROME_EXECUTABLE` (the variable Flutter itself honours) wins, then
/// `CHROME_PATH`, then the platform's usual install locations. Edge is
/// included last: it speaks the same protocol, and on Windows it is present on
/// machines where Chrome is not.
List<String> chromeCandidatePaths({
  required HostKind host,
  required Map<String, String> env,
}) {
  final candidates = <String>[];
  void add(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return;
    if (candidates.contains(trimmed)) return;
    candidates.add(trimmed);
  }

  add(env['CHROME_EXECUTABLE']);
  add(env['CHROME_PATH']);

  switch (host) {
    case HostKind.windows:
      final local = env['LOCALAPPDATA'];
      final programFiles = env['PROGRAMFILES'];
      final programFilesX86 = env['PROGRAMFILES(X86)'];
      for (final root in [local, programFiles, programFilesX86]) {
        if (root == null || root.trim().isEmpty) continue;
        add('${root.trimRight()}\\Google\\Chrome\\Application\\chrome.exe');
      }
      for (final root in [programFiles, programFilesX86, local]) {
        if (root == null || root.trim().isEmpty) continue;
        add('${root.trimRight()}\\Microsoft\\Edge\\Application\\msedge.exe');
      }
    case HostKind.macos:
      add('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome');
      final home = env['HOME'];
      if (home != null && home.trim().isNotEmpty) {
        add(
          '${home.trimRight()}/Applications/Google Chrome.app'
          '/Contents/MacOS/Google Chrome',
        );
      }
      add('/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge');
    case HostKind.linux:
      add('/usr/bin/google-chrome');
      add('/usr/bin/google-chrome-stable');
      add('/usr/bin/chromium');
      add('/usr/bin/chromium-browser');
      add('/snap/bin/chromium');
      add('/usr/bin/microsoft-edge');
  }
  return candidates;
}

/// Locates a browser executable, using [exists] to probe the filesystem.
///
/// [exists] is injected so the ordering logic is testable without installing
/// browsers on the machine running the tests.
String? findChromeExecutable({
  required HostKind host,
  required Map<String, String> env,
  required bool Function(String path) exists,
}) {
  for (final candidate in chromeCandidatePaths(host: host, env: env)) {
    if (exists(candidate)) return candidate;
  }
  return null;
}

/// [findChromeExecutable] against the real filesystem and environment.
String? locateChromeExecutable({HostKind? host, Map<String, String>? env}) =>
    findChromeExecutable(
      host: host ?? currentHostKind(),
      env: env ?? Platform.environment,
      exists: (path) => File(path).existsSync(),
    );

/// The command line used when Karmashala launches its own browser.
///
/// [userDataDir] is **always** a throwaway directory of ours. Three reasons,
/// and all matter: it keeps us out of the user's real profile, cookies and
/// signed in sessions; it stops an already-running Chrome on the default
/// profile from swallowing the launch and exiting without ever opening the
/// debugging port; and since Chrome 136 `--remote-debugging-port` is ignored
/// outright on the default data directory, so without this switch the launch
/// below would open no port at all.
List<String> chromeLaunchArguments({
  required int port,
  required String userDataDir,
  String? initialUrl,
}) => [
  '--remote-debugging-port=$port',
  '--user-data-dir=$userDataDir',
  '--no-first-run',
  '--no-default-browser-check',
  '--disable-background-networking',
  '--disable-backgrounding-occluded-windows',
  '--disable-renderer-backgrounding',
  initialUrl == null || initialUrl.isEmpty ? 'about:blank' : initialUrl,
];

/// Raises the standard "no browser installed" failure.
Never throwChromeNotFound() => throw BrowserException(
  BrowserFailure.chromeNotFound,
  describeBrowserFailure(BrowserFailure.chromeNotFound),
);
