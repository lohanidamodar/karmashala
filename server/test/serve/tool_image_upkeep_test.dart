import 'dart:io';

import 'package:agent_cli/stream.dart'
    show legacyToolImageDirectory, toolImageDirectory, useToolImageDirectory;
import 'package:karmashala_host/src/serve/tool_image_upkeep.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory data;

  setUp(() => data = Directory.systemTemp.createTempSync('kh-tool-images'));
  tearDown(() {
    try {
      data.deleteSync(recursive: true);
    } on FileSystemException {
      // A refusal here is Windows holding a handle, not the case's verdict.
    }
  });

  test('the cache moves under the data folder and is swept at once', () {
    final previous = toolImageDirectory;
    addTearDown(() => useToolImageDirectory(previous.path));
    final cache = Directory(p.join(data.path, 'tool-images'))..createSync();
    final stale = File(p.join(cache.path, 'abc-4.png'))
      ..writeAsBytesSync([1, 2, 3, 4])
      ..setLastModifiedSync(DateTime.now().subtract(const Duration(days: 60)));

    final timer = startToolImageUpkeep(data.path, sweepLegacy: false);
    addTearDown(timer.cancel);

    expect(toolImageDirectory.path, cache.path);
    expect(stale.existsSync(), isFalse);
    expect(timer.isActive, isTrue);
  });

  test('the legacy folder is not touched unless asked', () {
    final previous = toolImageDirectory;
    addTearDown(() => useToolImageDirectory(previous.path));
    final timer = startToolImageUpkeep(data.path, sweepLegacy: false);
    addTearDown(timer.cancel);
    expect(toolImageDirectory.path, isNot(legacyToolImageDirectory.path));
  });

  group('the limits, set in Settings → Server', () {
    test('default to 14 days and 256 MB when nothing is set', () {
      for (final raw in [null, '', 'not json', '{}', '[]']) {
        final limits = ToolImageLimits.fromSettings(raw);
        expect(limits.maxAge, const Duration(days: 14), reason: '$raw');
        expect(limits.maxBytes, 256 * 1024 * 1024, reason: '$raw');
      }
    });

    test('are read from settings.v1', () {
      final limits = ToolImageLimits.fromSettings(
        '{"toolImageMaxAgeDays": 3, "toolImageMaxMegabytes": 64}',
      );
      expect(limits.maxAge, const Duration(days: 3));
      expect(limits.maxBytes, 64 * 1024 * 1024);
    });

    test('a value out of range is held to the range, a wrong type ignored', () {
      final low = ToolImageLimits.fromSettings(
        '{"toolImageMaxAgeDays": 0, "toolImageMaxMegabytes": 1}',
      );
      expect(low.maxAge, const Duration(days: ToolImageLimits.minDays));
      expect(low.maxBytes, ToolImageLimits.minMegabytes * 1024 * 1024);
      final wrong = ToolImageLimits.fromSettings(
        '{"toolImageMaxAgeDays": "x", "toolImageMaxMegabytes": true}',
      );
      expect(wrong.maxAge, const Duration(days: 14));
      expect(wrong.maxBytes, 256 * 1024 * 1024);
    });

    test('each sweep reads them again, so a change needs no restart', () {
      final previous = toolImageDirectory;
      addTearDown(() => useToolImageDirectory(previous.path));
      final cache = Directory(p.join(data.path, 'tool-images'))..createSync();
      final threeDaysOld = File(p.join(cache.path, 'abc-4.png'))
        ..writeAsBytesSync([1, 2, 3, 4])
        ..setLastModifiedSync(DateTime.now().subtract(const Duration(days: 3)));
      var limits = ToolImageLimits.fromSettings(null);

      final upkeep = startToolImageUpkeep(
        data.path,
        sweepLegacy: false,
        limits: () => limits,
      );
      addTearDown(upkeep.cancel);
      expect(threeDaysOld.existsSync(), isTrue, reason: 'under 14 days');

      limits = ToolImageLimits.fromSettings('{"toolImageMaxAgeDays": 2}');
      upkeep.sweepNow();
      expect(threeDaysOld.existsSync(), isFalse);
    });
  });

  group('the cache as Settings → Server reads it', () {
    test('counts its files and their size, and clears them all', () {
      final cache = Directory(p.join(data.path, 'tool-images'))..createSync();
      File(p.join(cache.path, 'a-1.png')).writeAsBytesSync(List.filled(10, 1));
      File(p.join(cache.path, 'b-1.png')).writeAsBytesSync(List.filled(30, 1));

      final reading = readToolImageCache(cache);
      expect(reading.files, 2);
      expect(reading.bytes, 40);

      expect(clearToolImageCache(cache), 2);
      expect(readToolImageCache(cache).files, 0);
    });

    test('a cache never written reads as empty', () {
      final missing = Directory(p.join(data.path, 'tool-images'));
      final reading = readToolImageCache(missing);
      expect(reading.files, 0);
      expect(reading.bytes, 0);
      expect(clearToolImageCache(missing), 0);
    });
  });
}
