import 'dart:io';

import 'package:karmashala/src/features/terminal/data/theme_discovery.dart';
import 'package:flutter_test/flutter_test.dart';

late Directory _root;

Directory _dir(String name) =>
    Directory('${_root.path}${Platform.pathSeparator}$name')
      ..createSync(recursive: true);

File _file(Directory dir, String name, String content) =>
    File('${dir.path}${Platform.pathSeparator}$name')
      ..writeAsStringSync(content);

const _validGhostty = '''
background = #101010
foreground = #f0f0f0
palette = 0=#010101
''';

const _validWarp = '''
name: Sample
background: '#111111'
foreground: '#eeeeee'
terminal_colors:
  normal:
    black: '#000000'
''';

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('cg_theme_test');
  });
  tearDown(() {
    if (_root.existsSync()) _root.deleteSync(recursive: true);
  });

  group('discoverTerminalThemes', () {
    test('finds extensionless Ghostty themes', () {
      final themes = _dir('themes');
      _file(themes, 'Tomorrow Night Bright', _validGhostty);
      _file(themes, 'Nord', _validGhostty);

      final found = discoverTerminalThemes([
        themes,
      ], format: TerminalThemeFormat.ghostty);

      expect(found.map((t) => t.name).toList()..sort(), [
        'Nord',
        'Tomorrow Night Bright',
      ]);
      expect(
        found.every((t) => t.format == TerminalThemeFormat.ghostty),
        isTrue,
      );
    });

    test('finds Warp themes by extension only', () {
      final themes = _dir('warp');
      _file(themes, 'tokyo_night.yaml', _validWarp);
      _file(themes, 'nord.YML', _validWarp);
      _file(themes, 'readme.md', 'not a theme');
      _file(themes, 'notes.txt', 'not a theme');

      final found = discoverTerminalThemes([
        themes,
      ], format: TerminalThemeFormat.warp);

      expect(found.map((t) => t.name).toList()..sort(), [
        'nord',
        'tokyo_night',
      ]);
    });

    test('a missing directory is not an error', () {
      expect(
        discoverTerminalThemes([
          Directory('${_root.path}${Platform.pathSeparator}nope'),
        ], format: TerminalThemeFormat.ghostty),
        isEmpty,
      );
    });

    test('descends into subdirectories up to the depth cap', () {
      final themes = _dir('warp');
      final nested = _dir('warp/base16');
      final tooDeep = _dir('warp/a/b/c/d');
      _file(themes, 'top.yaml', _validWarp);
      _file(nested, 'nested.yaml', _validWarp);
      _file(tooDeep, 'deep.yaml', _validWarp);

      final found = discoverTerminalThemes(
        [themes],
        format: TerminalThemeFormat.warp,
        maxDepth: 2,
      );

      final names = found.map((t) => t.name).toList()..sort();
      expect(names, ['nested', 'top']);
    });

    test('stops at the file cap rather than walking a pathological tree', () {
      final themes = _dir('many');
      for (var i = 0; i < 30; i++) {
        _file(themes, 'theme$i.yaml', _validWarp);
      }

      final found = discoverTerminalThemes(
        [themes],
        format: TerminalThemeFormat.warp,
        maxFiles: 10,
      );

      expect(found, hasLength(10));
    });

    test('skips a file larger than the size cap', () {
      final themes = _dir('big');
      _file(themes, 'huge.yaml', 'x' * 2048);
      _file(themes, 'fine.yaml', _validWarp);

      final found = discoverTerminalThemes(
        [themes],
        format: TerminalThemeFormat.warp,
        maxFileBytes: 1024,
      );

      expect(found.map((t) => t.name), ['fine']);
    });

    test('the same file found twice is listed once', () {
      final themes = _dir('dup');
      _file(themes, 'one.yaml', _validWarp);

      final found = discoverTerminalThemes([
        themes,
        themes,
      ], format: TerminalThemeFormat.warp);

      expect(found, hasLength(1));
    });

    test('results are ordered so ids are stable between runs', () {
      final themes = _dir('order');
      for (final name in ['zebra.yaml', 'alpha.yaml', 'Mango.yaml']) {
        _file(themes, name, _validWarp);
      }

      final first = discoverTerminalThemes([
        themes,
      ], format: TerminalThemeFormat.warp);
      final second = discoverTerminalThemes([
        themes,
      ], format: TerminalThemeFormat.warp);

      expect(first.map((t) => t.id), second.map((t) => t.id));
    });
  });

  group('loadTerminalTheme', () {
    test('reads a Ghostty theme by id', () {
      final themes = _dir('g');
      final file = _file(themes, 'Nord', _validGhostty);

      final result = loadTerminalTheme(
        '${TerminalThemeFormat.ghostty.name}:${file.path}',
      );

      expect(result, isA<ThemeLoadOk>());
      expect((result as ThemeLoadOk).palette.background, '#101010');
    });

    test('reads a Warp theme by id', () {
      final themes = _dir('w');
      final file = _file(themes, 'sample.yaml', _validWarp);

      final result = loadTerminalTheme(
        '${TerminalThemeFormat.warp.name}:${file.path}',
      );

      expect(result, isA<ThemeLoadOk>());
      expect((result as ThemeLoadOk).palette.foreground, '#eeeeee');
    });

    test('a missing file is a readable error, not a crash', () {
      final result = loadTerminalTheme(
        '${TerminalThemeFormat.warp.name}:${_root.path}/gone.yaml',
      );

      expect(result, isA<ThemeLoadError>());
      expect((result as ThemeLoadError).reason, isNotEmpty);
    });

    test('a malformed theme is a readable error, not a crash', () {
      final themes = _dir('bad');
      final file = _file(themes, 'broken.yaml', "background: '#111\n  [: :");

      final result = loadTerminalTheme(
        '${TerminalThemeFormat.warp.name}:${file.path}',
      );

      expect(result, isA<ThemeLoadError>());
    });

    test('a Ghostty file with too little colour is rejected', () {
      final themes = _dir('thin');
      final file = _file(themes, 'Thin', 'font-size = 14\n');

      final result = loadTerminalTheme(
        '${TerminalThemeFormat.ghostty.name}:${file.path}',
      );

      expect(result, isA<ThemeLoadError>());
    });

    test('an unparseable id is an error rather than an exception', () {
      for (final id in ['', 'nonsense', 'notaformat:C:\\x', ':']) {
        expect(loadTerminalTheme(id), isA<ThemeLoadError>(), reason: id);
      }
    });

    test('the error never leaks the file path', () {
      // Reasons are surfaced in the UI; a path in one is an information leak
      // and unreadable noise besides.
      final result =
          loadTerminalTheme(
                '${TerminalThemeFormat.warp.name}:${_root.path}/x.yaml',
              )
              as ThemeLoadError;
      expect(result.reason, isNot(contains(_root.path)));
    });
  });

  group('Windows theme locations', () {
    test('Ghostty themes live beside the config under APPDATA', () {
      final dirs = ghosttyThemeDirectories(
        environment: {'APPDATA': r'C:\Users\a\AppData\Roaming'},
      );
      expect(dirs, isNotEmpty);
      expect(dirs.first.path, contains('ghostty'));
      expect(dirs.first.path, contains('themes'));
    });

    test('Warp themes are searched per channel', () {
      final dirs = warpThemeDirectories(
        environment: {'APPDATA': r'C:\Users\a\AppData\Roaming'},
      );
      expect(dirs.length, greaterThan(1));
      expect(dirs.first.path, contains('themes'));
      expect(
        dirs.map((d) => d.path).join(' '),
        contains('WarpPreview'),
        reason: 'preview installs keep their themes in their own channel',
      );
    });

    test('no APPDATA means no guesses', () {
      expect(ghosttyThemeDirectories(environment: const {}), isEmpty);
      expect(warpThemeDirectories(environment: const {}), isEmpty);
    });
  });
}
