/// Every subcommand answers `--help` with its usage and refuses a flag it does
/// not know — both before it binds, writes or signals anything. Found live:
/// `karmashala_host init --help` wrote `{}` to `~/.karmashala/server.json`.
library;

import 'dart:io';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'server_test_support.dart';

const _commands = [
  'serve',
  'init',
  'pair',
  'devices',
  'revoke',
  'agents',
  'attach',
  'list',
  'end',
  'stop',
  'relay',
  'probe-pty',
  'probe-store',
  'version',
];

void main() {
  late CapturingSink out;
  late CapturingSink err;
  setUp(() {
    out = CapturingSink();
    err = CapturingSink();
  });

  Future<int> cli(List<String> args) =>
      runHostCli(args, environment: kNowhereEnvironment, out: out, err: err);

  for (final command in _commands) {
    group(command, () {
      for (final help in ['--help', '-h']) {
        test('$help prints its usage and exits 0', () async {
          expect(await cli([command, help]), 0, reason: '${err.text}');
          expect(out.text.toString(), contains('karmashala_host $command'));
          expect(err.text.toString(), isEmpty);
        });
      }

      test('--help wins over every other argument', () async {
        expect(
          await cli([command, '--data-dir=/nonexistent/x', '--help']),
          0,
          reason: '${err.text}',
        );
        expect(out.text.toString(), contains('karmashala_host $command'));
      });

      test('an unknown flag is refused, by name, with the usage', () async {
        expect(await cli([command, '--no-such-flag']), 2);
        // The relay's own parser refuses without echoing: a guessed
        // `--token=…` must not be printed back.
        if (command != 'relay') {
          expect(err.text.toString(), contains('--no-such-flag'));
        }
        expect(err.text.toString(), contains('karmashala_host $command'));
        expect(out.text.toString(), isEmpty);
      });
    });
  }

  test('a value flag without its value, a switch with one, and a word too '
      'many are refused', () async {
    expect(await cli(['init', '--data-dir']), 2);
    expect(err.text.toString(), contains('--data-dir needs a value'));
    expect(await cli(['init', '--force=yes']), 2);
    expect(err.text.toString(), contains('--force takes no value'));
    expect(await cli(['end', 'one', 'two']), 2);
    expect(err.text.toString(), contains('unexpected argument "two"'));
    expect(await cli(['init', 'stray']), 2);
    expect(err.text.toString(), contains('unexpected argument "stray"'));
    expect(out.text.toString(), isEmpty);
  });

  test('the top-level usage names every command and how to ask one', () async {
    expect(await cli(['--help']), 0);
    for (final command in _commands) {
      expect(out.text.toString(), contains('karmashala_host $command'));
    }
    expect(out.text.toString(), contains('<command> --help'));
  });

  // The command as it runs: its own process, a home and runtime dir of its
  // own, so "touches nothing" is checked where it would have written.
  group('as a process', () {
    late Directory root;
    late Directory home;
    setUp(() {
      root = Directory.systemTemp.createTempSync('kh-cli');
      home = Directory(p.join(root.path, 'home'))..createSync();
    });
    tearDown(() => root.deleteSync(recursive: true));

    Future<ProcessResult> run(List<String> args) => Process.run(
      Platform.resolvedExecutable,
      ['bin/karmashala_host.dart', ...args],
      environment: {
        'HOME': home.path,
        'USERPROFILE': home.path,
        'XDG_RUNTIME_DIR': p.join(root.path, 'run'),
        kHostDirectoryEnvironmentVariable: p.join(root.path, 'host'),
      },
    ).timeout(const Duration(minutes: 2));

    List<String> leftBehind() => [
      for (final entity in root.listSync(recursive: true))
        p.relative(entity.path, from: root.path),
    ];

    for (final args in [
      ['init', '--help'],
      ['init', '-h'],
      ['init', '--bogus'],
      ['init', '--name=box', '--bogus'],
      ['serve', '--help'],
      ['serve', '--standalone', '--bogus'],
      ['stop', '--help'],
    ]) {
      test('`${args.join(' ')}` writes nothing anywhere', () async {
        final result = await run(args);
        expect(
          result.exitCode,
          args.any((a) => a.startsWith('--bogus')) ? 2 : 0,
          reason: '${result.stdout}${result.stderr}',
        );
        expect(leftBehind(), ['home']);
      });
    }
  });
}
