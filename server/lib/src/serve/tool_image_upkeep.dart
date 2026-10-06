import 'dart:async';
import 'dart:io';

import 'package:agent_cli/stream.dart'
    show
        kToolImageFolderName,
        legacyToolImageDirectory,
        sweepToolImages,
        useToolImageDirectory;
import 'package:path/path.dart' as p;

/// Points the tool-image cache at `<data>/tool-images` and keeps it bounded:
/// swept now and every [every]. [sweepLegacy] also drains the old folder in
/// the system temp, which every server on the machine shared.
Timer startToolImageUpkeep(
  String dataDirectory, {
  Duration every = const Duration(days: 1),
  bool sweepLegacy = true,
}) {
  final cache = Directory(p.join(dataDirectory, kToolImageFolderName));
  useToolImageDirectory(cache.path);
  void sweep() {
    sweepToolImages(cache);
    if (sweepLegacy) sweepToolImages(legacyToolImageDirectory);
  }

  sweep();
  return Timer.periodic(every, (_) => sweep());
}
