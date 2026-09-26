@Tags(['live-wsl'])
library;

import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/projects/application/wsl_path_existence.dart';

/// **Whether a WSL folder is there, asked through a real `wsl.exe`.**
///
/// The unit tests prove the argv and the parse, and run the script under a
/// POSIX `sh`. What only a Windows machine with a distribution can answer is
/// whether the *command line* survives: a path with a space, a quote, `$`,
/// unicode or a newline goes from Dart to `CreateProcess` to `wsl.exe` to
/// `sh` as one argument each, and comes back as one digit each.
///
/// How to run it: `tool/live_tests.ps1 -Family wsl`, or see PROJECT.md §18.
void main() {
  final probe = _probeWsl();
  if (probe != null) {
    test('live WSL path test is skipped', () {}, skip: probe);
    return;
  }

  late String distribution;
  late String root;

  setUpAll(() async {
    // `wsl.exe -e` runs in the default distribution, which is therefore
    // running by the time anything below asks.
    distribution = await _wsl(['sh', '-c', r'printf %s "$WSL_DISTRO_NAME"']);
    root = await _wsl(['mktemp', '-d', '-t', 'karmashala-exists-XXXXXX']);
  });

  tearDownAll(() => _wsl(['rm', '-rf', root]));

  test('awkward paths cross wsl.exe one argument each, and the answer is in '
      'order', () async {
    final names = [
      'plain',
      'with space',
      'it\'s "quoted"',
      r'$HOME and $(touch pwned) `id`',
      'काम-作業',
      'two\nlines',
      r'back\slash and trailing\',
    ];
    final paths = [for (final name in names) '$root/$name'];
    // Made inside the distribution, and only every other one.
    for (final (index, path) in paths.indexed) {
      if (index.isEven) await _wsl(['mkdir', '-p', '--', path]);
    }

    final checker = WslPathExistence(
      host: const LocalCommandRunner(),
      now: DateTime.now,
    );
    final answers = await Future.wait([
      for (final path in paths) checker.exists(distribution, path),
    ]);

    expect(answers, [for (final (index, _) in paths.indexed) index.isEven]);
    expect(
      await _wsl([
        'sh',
        '-c',
        'ls -A -- "\$1" | grep -c pwned || true',
        '-',
        root,
      ]),
      '0',
      reason: 'a path is data: nothing in one ran',
    );
  });

  test('a distribution that is not running is not started', () async {
    final checker = WslPathExistence(
      host: const LocalCommandRunner(),
      now: DateTime.now,
    );
    const stopped = 'karmashala-no-such-distribution';

    expect(await checker.exists(stopped, '/'), isNull);
  });
}

/// Why this suite cannot run here, or null when it can.
String? _probeWsl() {
  if (!Platform.isWindows) return 'Asking wsl.exe is Windows-only.';
  try {
    final hello = Process.runSync('wsl.exe', ['-e', 'sh', '-c', 'echo ok']);
    if (hello.exitCode != 0 || !'${hello.stdout}'.contains('ok')) {
      return 'No WSL distribution answered.';
    }
  } on ProcessException {
    return 'wsl.exe is not on this machine.';
  }
  return null;
}

/// One command inside the default distribution, trimmed. Throws on failure so
/// a broken fixture cannot look like a broken feature.
Future<String> _wsl(List<String> arguments) async {
  final result = await Process.run('wsl.exe', ['-e', ...arguments]);
  if (result.exitCode != 0) {
    throw StateError('wsl ${arguments.join(' ')} failed: ${result.stderr}');
  }
  return '${result.stdout}'.trim();
}
