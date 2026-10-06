import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/src/sessions/tool_images.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp_directory.dart';

/// The folder tool images are spilled into is bounded: by age, then by size.
void main() {
  late Directory dir;
  final now = DateTime(2026, 10, 6, 12);

  setUp(() => dir = Directory.systemTemp.createTempSync('tool_image_cache'));
  tearDown(() => removeTempDirectory(dir));

  File put(String name, int bytes, {required Duration age}) =>
      File(p.join(dir.path, name))
        ..writeAsBytesSync(List.filled(bytes, 1))
        ..setLastModifiedSync(now.subtract(age));

  test('files unused past the age are dropped, recent ones kept', () {
    put('old.png', 10, age: const Duration(days: 20));
    put('new.png', 10, age: const Duration(days: 1));

    final swept = sweepToolImages(
      dir,
      maxAge: const Duration(days: 14),
      maxBytes: 1 << 20,
      now: now,
    );

    expect(swept, 1);
    expect(File(p.join(dir.path, 'old.png')).existsSync(), isFalse);
    expect(File(p.join(dir.path, 'new.png')).existsSync(), isTrue);
  });

  test('past the size cap, the least recently used go first', () {
    put('a.png', 40, age: const Duration(hours: 3));
    put('b.png', 40, age: const Duration(hours: 2));
    put('c.png', 40, age: const Duration(hours: 1));

    final swept = sweepToolImages(
      dir,
      maxAge: const Duration(days: 14),
      maxBytes: 100,
      now: now,
    );

    expect(swept, 1);
    expect(File(p.join(dir.path, 'a.png')).existsSync(), isFalse);
    expect(File(p.join(dir.path, 'b.png')).existsSync(), isTrue);
    expect(File(p.join(dir.path, 'c.png')).existsSync(), isTrue);
  });

  test('a folder that is not there sweeps nothing', () {
    expect(sweepToolImages(Directory(p.join(dir.path, 'none'))), 0);
  });

  test('images spill into the folder it is pointed at, and a reuse counts '
      'as use', () {
    final previous = toolImageDirectory;
    addTearDown(() => useToolImageDirectory(previous.path));
    final cache = p.join(dir.path, 'tool-images');
    useToolImageDirectory(cache);

    final data = base64Encode([1, 2, 3, 4]);
    final path = spillToolImage(data, mimeType: 'image/png')!;
    expect(p.isWithin(cache, path), isTrue);

    final stale = DateTime.now().subtract(const Duration(days: 30));
    File(path).setLastModifiedSync(stale);
    expect(spillToolImage(data, mimeType: 'image/png'), path);
    expect(
      File(path).lastModifiedSync().isAfter(
        DateTime.now().subtract(const Duration(days: 1)),
      ),
      isTrue,
    );
  });

  test('a cache image that is gone reads as no longer kept; any other '
      'image as no longer on disk', () {
    final cached = p.join(
      dir.path,
      'tool-images',
      'cbf29ce484222325-12.png',
    );
    expect(missingImageNote(cached), 'That image is no longer kept.');
    expect(
      missingImageNote(r'C:\repo\shot.png'),
      'That image is no longer on disk.',
    );
  });
}
