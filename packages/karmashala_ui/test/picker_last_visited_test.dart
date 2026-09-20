import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/picking.dart';

/// `reg.exe` output for a key holding [rows] — value name to blob hex.
String _query(Map<String, String> rows) => [
  r'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer'
      r'\ComDlg32\LastVisitedPidlMRU',
  for (final row in rows.entries)
    '    ${row.key}    REG_BINARY    ${row.value}',
  '    MRUListEx    REG_BINARY    11000000FFFFFFFF',
  '',
].join('\r\n');

/// A value blob: the executable's name in UTF-16, NUL-terminated, then bytes
/// standing in for the ITEMIDLIST, which this code never reads.
String _blob(String executable, {String tail = '14001F0005398E08'}) {
  final buffer = StringBuffer();
  for (final unit in executable.codeUnits) {
    buffer.write((unit & 0xFF).toRadixString(16).padLeft(2, '0'));
    buffer.write((unit >> 8).toRadixString(16).padLeft(2, '0'));
  }
  buffer.write('0000');
  buffer.write(tail);
  return buffer.toString().toUpperCase();
}

ProcessResult _ok(String stdout) => ProcessResult(0, 0, stdout, '');
ProcessResult _failed() => ProcessResult(0, 1, '', 'ERROR: not found.');

void main() {
  group('forgetLastVisitedFolder', () {
    test('deletes only the row naming this executable', () async {
      final calls = <List<String>>[];
      final removed = await forgetLastVisitedFolder(
        executableName: 'karmashala.exe',
        run: (arguments) async {
          calls.add(arguments);
          if (arguments.first == 'query') {
            return _ok(
              _query({
                '3': _blob('claude.exe'),
                '17': _blob('sshetu.exe'),
                '18': _blob('karmashala.exe'),
              }),
            );
          }
          return _ok('');
        },
      );

      expect(removed, 1);
      final deletes = calls.where((c) => c.first == 'delete');
      expect(deletes, hasLength(1));
      expect(deletes.single, containsAllInOrder(['/v', '18', '/f']));
    });

    test('drops every row of ours, not just the first', () async {
      final deleted = <String>[];
      final removed = await forgetLastVisitedFolder(
        executableName: 'karmashala.exe',
        run: (arguments) async {
          if (arguments.first == 'query') {
            return _ok(
              _query({
                '4': _blob('karmashala.exe'),
                '9': _blob('code.exe'),
                '18': _blob('karmashala.exe'),
              }),
            );
          }
          deleted.add(arguments[arguments.indexOf('/v') + 1]);
          return _ok('');
        },
      );

      expect(removed, 2);
      expect(deleted, ['4', '18']);
    });

    test('matches the executable name case-insensitively', () async {
      final removed = await forgetLastVisitedFolder(
        executableName: 'Karmashala.EXE',
        run: (arguments) async => arguments.first == 'query'
            ? _ok(_query({'2': _blob('karmashala.exe')}))
            : _ok(''),
      );
      expect(removed, 1);
    });

    test('a name that merely starts the same is left alone', () async {
      final removed = await forgetLastVisitedFolder(
        executableName: 'karmashala.exe',
        run: (arguments) async => arguments.first == 'query'
            ? _ok(_query({'2': _blob('karmashala_mcp.exe')}))
            : _ok(''),
      );
      expect(removed, 0);
    });

    test('MRUListEx is never a candidate', () async {
      final calls = <List<String>>[];
      await forgetLastVisitedFolder(
        executableName: 'MRUListEx',
        run: (arguments) async {
          calls.add(arguments);
          return arguments.first == 'query' ? _ok(_query({})) : _ok('');
        },
      );
      expect(calls.where((c) => c.first == 'delete'), isEmpty);
    });

    test('a key that is not there costs nothing and reports nothing', () async {
      final removed = await forgetLastVisitedFolder(
        executableName: 'karmashala.exe',
        run: (arguments) async => _failed(),
      );
      expect(removed, 0);
    });

    test('a registry that throws is survived, not rethrown', () async {
      final removed = await forgetLastVisitedFolder(
        executableName: 'karmashala.exe',
        run: (arguments) async => throw const ProcessException('reg.exe', []),
      );
      expect(removed, 0);
    });

    test('a delete that refuses is not counted', () async {
      final removed = await forgetLastVisitedFolder(
        executableName: 'karmashala.exe',
        run: (arguments) async => arguments.first == 'query'
            ? _ok(_query({'18': _blob('karmashala.exe')}))
            : _failed(),
      );
      expect(removed, 0);
    });

    test('malformed hex names nothing, so nothing is deleted', () async {
      final removed = await forgetLastVisitedFolder(
        executableName: 'karmashala.exe',
        run: (arguments) async => arguments.first == 'query'
            ? _ok(_query({'18': 'ZZZZ', '19': '14'}))
            : _ok(''),
      );
      expect(removed, 0);
    });
  });
  group('forgetRemoteRecentFolders', () {
    /// `reg.exe query` output for OpenSavePidlMRU\<ext>.
    String recent(Map<String, String> rows) => [
      r'HKEY_CURRENT_USER\...\ComDlg32\OpenSavePidlMRU',
      for (final row in rows.entries)
        '    ${row.key}    REG_BINARY    ${row.value}',
      '    MRUListEx    REG_BINARY    11000000FFFFFFFF',
      '',
    ].join('\r\n');

    /// A blob whose display names contain [text], the way a real PIDL's do.
    String blobNaming(String text) {
      final buffer = StringBuffer('14001F00');
      for (final unit in text.codeUnits) {
        buffer.write((unit & 0xFF).toRadixString(16).padLeft(2, '0'));
        buffer.write((unit >> 8).toRadixString(16).padLeft(2, '0'));
      }
      return buffer.toString().toUpperCase();
    }

    test('drops only the rows naming a WSL share', () async {
      final deleted = <String>[];
      final removed = await forgetRemoteRecentFolders(
        extensions: const ['apk'],
        run: (arguments) async {
          if (arguments.first == 'query') {
            if (!arguments[1].endsWith(r'\*')) return _ok(recent({}));
            return _ok(
              recent({
                '3': blobNaming(r'C:\Users\me\Downloads'),
                '14': blobNaming(r'wsl$'),
                '17': blobNaming('wsl.localhost'),
              }),
            );
          }
          deleted.add(
            '${arguments[1]}|${arguments[arguments.indexOf('/v') + 1]}',
          );
          return _ok('');
        },
      );

      expect(removed, 2);
      expect(
        deleted.every((d) => d.endsWith('|14') || d.endsWith('|17')),
        isTrue,
      );
      expect(
        deleted.any((d) => d.endsWith('|3')),
        isFalse,
        reason: "another app's local folder is not ours to delete",
      );
    });

    test(
      r'always reads `*`, which is the key a stray extension falls back to',
      () async {
        final asked = <String>[];
        await forgetRemoteRecentFolders(
          extensions: const ['apk', 'app'],
          run: (arguments) async {
            if (arguments.first == 'query') asked.add(arguments[1]);
            return _ok(recent({}));
          },
        );
        expect(asked.any((k) => k.endsWith(r'\*')), isTrue);
        expect(asked.any((k) => k.endsWith(r'\apk')), isTrue);
        expect(asked.any((k) => k.endsWith(r'\app')), isTrue);
      },
    );

    test('a key that does not exist costs nothing', () async {
      final removed = await forgetRemoteRecentFolders(
        extensions: const ['apk'],
        run: (arguments) async => _failed(),
      );
      expect(removed, 0);
    });

    test('MRUListEx is never deleted', () async {
      final deleted = <String>[];
      await forgetRemoteRecentFolders(
        extensions: const [],
        run: (arguments) async {
          if (arguments.first == 'query') {
            return _ok(recent({'1': blobNaming(r'wsl$')}));
          }
          deleted.add(arguments[arguments.indexOf('/v') + 1]);
          return _ok('');
        },
      );
      expect(deleted, ['1']);
    });
  });
}
