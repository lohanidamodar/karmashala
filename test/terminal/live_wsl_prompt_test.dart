@Tags(['live-wsl'])
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_pty/flutter_pty.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/data/pty_launch.dart';
import 'package:karmashala/src/features/terminal/data/process_shutdown.dart';
import 'package:karmashala_terminal_core/profiles.dart';

/// What a **prompt** turns into by the time the agent in a WSL pane reads it.
///
/// The launch this app builds for a WSL agent is a command line that gets
/// parsed **twice**: `cmd.exe` reads it, and then `wsl.exe … -- <command>`
/// hands the tail to the distribution's login shell, which reads it again under
/// POSIX rules. Nothing above the PTY can see that second parser, and unit
/// tests pinning the command line only pin what we *wrote*, not what a shell
/// makes of it.
///
/// The launch that was reported on 2026-09-03 died as
///
///   zsh:1: unmatched "
///
/// — a multi-line prompt, truncated by `cmd` at its first newline with the
/// opening quote still dangling, so the agent never started. Measured on the
/// same chain and worse: `` `id -u` `` and `$(id -u)` inside a prompt were
/// **executed**, and `$(touch …)` really created the file. A prompt is written
/// by agents and pasted by users; it is not trusted text, and it must never
/// reach a shell as code.
///
/// So every case here is a prompt that used to be mangled or run, asserted on
/// the bytes the process actually received. The argument is written to a file
/// inside the distribution rather than read off the pane, because a ConPTY
/// re-flows and cursor-addresses what it paints and a newline in a prompt is
/// exactly what has to survive.
///
/// Skips itself where there is no WSL or no `flutter_pty.dll` to spawn a real
/// ConPTY with — the same shape as `live_wsl_pane_test.dart`.
void main() {
  final probe = _probe();
  if (probe != null) {
    test('live WSL prompt test is skipped', () {}, skip: probe);
    return;
  }
  final distro = _defaultDistro()!;
  _installProbe(distro);

  /// Prompts that were each mangled, truncated or executed before this test
  /// existed. The value is what the agent must receive, byte for byte.
  const prompts = <String, String>{
    'a double quote': 'he said "hello" to me',
    'an unbalanced double quote': 'he said "hello',
    'a single quote': "it's a trap",
    'a backtick': 'run `id -u` and report',
    'a command substitution': r'run $(id -u) and report',
    'a bare variable': r'my $HOME is here',
    'a percent sign': 'about 50%USERNAME% done',
    'a newline': 'line one\nline two',
    'the reported prompt': 'Say "hi" and run `echo boom` for me',
    'a multi-line prompt with everything in it':
        'Fix the "auth" bug.\n\nUse `git log` and \$(date).\n50% done.',
  };

  group('a WSL agent pane receives the prompt as written', () {
    for (final entry in prompts.entries) {
      test(entry.key, () async {
        final received = await _throughPane(distro, entry.value);
        expect(received, entry.value);
      }, timeout: const Timeout(Duration(seconds: 90)));
    }
  });

  group('and so does the same command in an external terminal', () {
    // `wrapForExternalTerminal` crosses the identical `wsl.exe … --` hand-off,
    // and `_startInExternalTerminal` puts the prompt through it. Driven with
    // `Process.run`, whose Windows argv rendering is the same escaping every
    // one of those terminals applies.
    for (final entry in prompts.entries) {
      test(entry.key, () async {
        final received = await _throughExternalTerminal(distro, entry.value);
        expect(received, entry.value);
      }, timeout: const Timeout(Duration(seconds: 60)));
    }
  });

  test('and nothing in a prompt is ever executed', () async {
    // The security half. Each of these ran for real before the fix: the
    // measured pane turned `run `id -u` now` into `run 1000 now`, and this
    // exact payload created the file.
    await _runIn(distro, ['/bin/rm', '-f', _pwnedPath]);
    for (final payload in [
      'x\$(touch $_pwnedPath)y',
      'x`touch $_pwnedPath`y',
      'a; touch $_pwnedPath; b',
      'a && touch $_pwnedPath',
      'a | touch $_pwnedPath',
      'a > $_pwnedPath b',
    ]) {
      expect(await _throughPane(distro, payload), payload);
      expect(await _throughExternalTerminal(distro, payload), payload);
    }
    final listing = await _runIn(distro, ['/bin/ls', '-1', _pwnedPath]);
    expect(
      listing.exitCode,
      isNot(0),
      reason:
          'a prompt reached the login shell as code and ran: $_pwnedPath '
          'exists. ${listing.stdout}',
    );
  }, timeout: const Timeout(Duration(seconds: 240)));

  test('one argument in is one argument out', () async {
    // Word splitting is the quieter half of the same bug: a multi-word prompt
    // that arrives as several arguments is silently ignored by every one of
    // these CLIs rather than reported.
    await _throughPane(distro, 'three separate words');
    final argc = await _runIn(distro, ['/bin/cat', _argcPath]);
    expect('${argc.stdout}'.trim(), '1');
  }, timeout: const Timeout(Duration(seconds: 90)));
}

const _probePath = '/tmp/karmashala_prompt_probe';
const _argPath = '/tmp/karmashala_prompt_arg';
const _argcPath = '/tmp/karmashala_prompt_argc';
const _pwnedPath = '/tmp/karmashala_prompt_pwned';

/// A one-argument recorder: it writes what it was handed, and how many
/// arguments it was handed, where the test can read them back unrendered.
void _installProbe(String distro) {
  final script =
      '#!/bin/sh\n'
      'printf %s "\$1" > $_argPath\n'
      'printf %s "\$#" > $_argcPath\n'
      'echo KARMASHALA_PROBE_DONE\n';
  // `--exec` hands `wsl.exe` an argv byte for byte with no shell in the way
  // (measured), so the script can simply be one of the arguments.
  final write = Process.runSync('wsl.exe', [
    '-d',
    distro,
    '--exec',
    '/bin/sh',
    '-c',
    'printf %s "\$1" > $_probePath; chmod +x $_probePath',
    'sh',
    script,
  ], stdoutEncoding: utf8, stderrEncoding: utf8);
  if (write.exitCode != 0) {
    throw StateError('could not install the probe: ${write.stderr}');
  }
}

Future<ProcessResult> _runIn(String distro, List<String> argv) =>
    Process.run('wsl.exe', [
      '-d',
      distro,
      '--exec',
      ...argv,
    ], stdoutEncoding: utf8, stderrEncoding: utf8);

Future<void> _clear(String distro) =>
    _runIn(distro, ['/bin/rm', '-f', _argPath, _argcPath]);

Future<String> _readArgument(String distro) async {
  final result = await _runIn(distro, ['/bin/cat', _argPath]);
  expect(result.exitCode, 0, reason: 'the probe never ran: ${result.stderr}');
  return result.stdout as String;
}

/// [prompt] through the real ConPTY launch this app builds for a WSL agent.
Future<String> _throughPane(String distro, String prompt) async {
  await _clear(distro);
  final launch = wrapForPty(
    ShellCommand(executable: _probePath, arguments: [prompt]),
    LaunchContext.wsl(distro),
  );
  final buffer = StringBuffer();
  final pty = Pty.start(
    launch.executable,
    arguments: launch.arguments,
    environment: {...Platform.environment, ...launch.environment},
    rows: 30,
    columns: 200,
  );
  pty.output.listen(
    (bytes) =>
        buffer.write(const Utf8Decoder(allowMalformed: true).convert(bytes)),
  );
  final deadline = DateTime.now().add(const Duration(seconds: 40));
  while (DateTime.now().isBefore(deadline)) {
    if (buffer.toString().contains('KARMASHALA_PROBE_DONE')) break;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  expect(
    buffer.toString(),
    contains('KARMASHALA_PROBE_DONE'),
    reason: 'the pane never reached the probe: $buffer',
  );
  await shutdownProcess(kill: pty.kill, exitCode: pty.exitCode, pid: pty.pid);
  return _readArgument(distro);
}

/// [prompt] through the argv an external terminal is handed, rendered by
/// `Process.start`'s Windows escaping — the same escaping those terminals use.
Future<String> _throughExternalTerminal(String distro, String prompt) async {
  await _clear(distro);
  final argv = wrapForExternalTerminal(
    ShellCommand(executable: _probePath, arguments: [prompt]),
    LaunchContext.wsl(distro),
  );
  expect(argv.first, 'wsl.exe');
  final result = await Process.run(
    argv.first,
    argv.sublist(1),
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  expect(result.exitCode, 0, reason: 'wsl.exe refused: ${result.stderr}');
  return _readArgument(distro);
}

/// The distribution `wsl.exe` opens by default, or null when there is none.
String? _defaultDistro() {
  try {
    final result = Process.runSync('wsl.exe', [
      '-e',
      'sh',
      '-c',
      r'printf %s "$WSL_DISTRO_NAME"',
    ]);
    final name = '${result.stdout}'.trim();
    return name.isEmpty ? null : name;
  } on ProcessException {
    return null;
  }
}

/// Why this suite cannot run here, or null when it can. See
/// `live_wsl_pane_test.dart` for why the DLL is loaded by full path.
String? _probe() {
  if (!Platform.isWindows) return 'A WSL pane is a Windows ConPTY.';
  if (_defaultDistro() == null) return 'No WSL distribution answered.';
  final candidates = [
    r'build\windows\x64\runner\Debug\flutter_pty.dll',
    r'build\windows\x64\runner\Release\flutter_pty.dll',
    r'C:\Program Files\Karmashala\flutter_pty.dll',
  ];
  for (final path in candidates) {
    final file = File(path);
    if (!file.existsSync()) continue;
    try {
      DynamicLibrary.open(file.absolute.path);
      return null;
    } on ArgumentError {
      continue;
    }
  }
  return 'No flutter_pty.dll to spawn a ConPTY with; build the app first.';
}
