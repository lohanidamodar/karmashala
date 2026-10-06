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
}
