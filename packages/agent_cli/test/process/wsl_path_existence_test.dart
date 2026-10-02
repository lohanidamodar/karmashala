import 'dart:io';

import 'package:agent_cli/src/process/wsl_path_existence.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A WSL folder is asked about from inside its distribution, many at a time,
/// and never by a stat over `\\wsl.localhost`.
///
/// The author's machine has no WSL, so what is proved here is the argv, the
/// parse, and — against this machine's own `sh` — the script itself.
void main() {
  const awkward = [
    '/home/me/plain',
    '/home/me/with space',
    '/home/me/it\'s "quoted"',
    r'/home/me/$HOME and $(touch pwned) `id`',
    '/home/me/काम-作業',
    '/home/me/two\nlines',
    '/home/me/semi;colon && rm -rf x',
  ];

  group('the wsl.exe call', () {
    test('asks one distribution about many paths in one call, --exec, with '
        'the paths after the script and never in it', () {
      final arguments = wslDirectoriesExistArguments(
        distribution: 'Ubuntu 22.04',
        paths: awkward,
      );

      expect(arguments.take(6), [
        '-d',
        'Ubuntu 22.04',
        '--exec',
        'sh',
        '-c',
        wslDirectoriesExistScript,
      ]);
      expect(arguments[6], 'karmashala-exists', reason: r'$0 is a name');
      expect(arguments.skip(7), awkward, reason: 'verbatim, one argument each');
      for (final path in awkward) {
        expect(wslDirectoriesExistScript, isNot(contains(path)));
      }
      expect(arguments, isNot(contains('--')), reason: 'no login shell');
    });

    test('is a bounded request for the Windows host', () {
      final request = wslDirectoriesExistRequest(
        distribution: 'archlinux',
        paths: const ['/srv/app'],
      );
      expect(request.executable, 'wsl.exe');
      expect(request.workingDirectory, isNull);
      expect(request.runInShell, isFalse);
      expect(request.timeout, isNotNull);
    });

    test('names no share', () {
      final text = wslDirectoriesExistArguments(
        distribution: 'Ubuntu',
        paths: const ['/home/me/app'],
      ).join(' ');
      expect(text, isNot(contains('wsl.localhost')));
      expect(text, isNot(contains(r'wsl$')));
    });
  });

  group('batches', () {
    test('a screenful is one call', () {
      final paths = [for (var i = 0; i < 40; i++) '/home/me/project-$i'];
      expect(wslExistenceBatches(paths), [paths]);
    });

    test('a workspace too long for one command line is cut in order, and '
        'every path is asked once', () {
      final paths = [for (var i = 0; i < 1000; i++) '/home/me/${'x' * 90}-$i'];
      final batches = wslExistenceBatches(paths);

      expect(batches.length, greaterThan(1));
      expect(batches.expand((batch) => batch), paths);
      for (final batch in batches) {
        final length = wslDirectoriesExistArguments(
          distribution: 'Ubuntu',
          paths: batch,
        ).fold<int>(0, (sum, argument) => sum + argument.length + 3);
        expect(length, lessThan(32767));
      }
    });

    test('one path longer than a call still goes out, alone', () {
      final long = '/${'y' * 30000}';
      expect(wslExistenceBatches(['/a', long, '/b']), [
        ['/a'],
        [long],
        ['/b'],
      ]);
    });
  });

  group('the answer', () {
    test('is one per path, in order', () {
      expect(parseWslDirectoriesExist('${kWslExistsMarker}101\n', count: 3), [
        true,
        false,
        true,
      ]);
    });

    test('survives a banner, CRLF and stray NULs around it', () {
      expect(
        parseWslDirectoriesExist(
          'welcome to arch\r\n\u0000${kWslExistsMarker}01\r\n',
          count: 2,
        ),
        [false, true],
      );
    });

    test('nothing asked is nothing answered', () {
      expect(
        parseWslDirectoriesExist('$kWslExistsMarker\n', count: 0),
        isEmpty,
      );
    });

    test('anything else is not an answer — unknown, never "missing"', () {
      for (final output in [
        '',
        'The distribution is not running.',
        '${kWslExistsMarker}10\n',
        '${kWslExistsMarker}1x1\n',
        '1 0 1\n',
      ]) {
        expect(
          parseWslDirectoriesExist(output, count: 3),
          isNull,
          reason: output,
        );
      }
    });
  });

  group('the script, run by this machine\'s own sh', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('kexists_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('tells a directory from a file and from nothing, whatever the name '
        'holds, and runs none of it', () async {
      final names = [for (final path in awkward) p.basename(path)];
      final present = <String>[];
      for (final (index, name) in names.indexed) {
        final path = p.join(tmp.path, name);
        // Every other one exists, so the order of the answer is proved too.
        if (index.isEven) Directory(path).createSync();
        present.add(path);
      }
      final file = p.join(tmp.path, 'a file');
      File(file).createSync();
      final asked = [...present, file, p.join(tmp.path, 'never made')];

      final arguments = wslDirectoriesExistArguments(
        distribution: 'unused',
        paths: asked,
      );
      // Everything after `--exec`: what the distribution is handed.
      final result = await Process.run(
        arguments[3],
        arguments.sublist(4),
        workingDirectory: tmp.path,
      );

      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(
        parseWslDirectoriesExist('${result.stdout}', count: asked.length),
        [for (final (index, _) in names.indexed) index.isEven, false, false],
      );
      expect(
        File(p.join(tmp.path, 'pwned')).existsSync(),
        isFalse,
        reason: 'a path is data',
      );
    }, skip: Platform.isWindows ? 'needs a POSIX sh' : null);
  });
}
