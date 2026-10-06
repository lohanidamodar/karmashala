import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/stream.dart'
    show
        kToolImageFolderName,
        kToolImageMaxAge,
        kToolImageMaxBytes,
        legacyToolImageDirectory,
        sweepToolImages,
        useToolImageDirectory;
import 'package:path/path.dart' as p;

/// How long an unused tool image is kept and how much the cache may hold, as
/// Settings → Server sets them in `settings.v1`; the defaults otherwise.
class ToolImageLimits {
  const ToolImageLimits({
    this.maxAge = kToolImageMaxAge,
    this.maxBytes = kToolImageMaxBytes,
  });

  /// The `settings.v1` keys Settings writes.
  static const maxAgeDaysKey = 'toolImageMaxAgeDays';
  static const maxMegabytesKey = 'toolImageMaxMegabytes';

  static const minDays = 1;
  static const maxDays = 365;
  static const minMegabytes = 16;
  static const maxMegabytes = 16 * 1024;

  /// Reads [raw] (`settings.v1`); a missing or wrong-typed value is the
  /// default, one out of range is held to the range.
  factory ToolImageLimits.fromSettings(String? raw) {
    Object? decoded;
    try {
      decoded = raw == null ? null : jsonDecode(raw);
    } on FormatException {
      decoded = null;
    }
    final settings = decoded is Map ? decoded : const {};
    final days = settings[maxAgeDaysKey];
    final megabytes = settings[maxMegabytesKey];
    return ToolImageLimits(
      maxAge: days is int
          ? Duration(days: days.clamp(minDays, maxDays))
          : kToolImageMaxAge,
      maxBytes: megabytes is int
          ? megabytes.clamp(minMegabytes, maxMegabytes) * 1024 * 1024
          : kToolImageMaxBytes,
    );
  }

  final Duration maxAge;
  final int maxBytes;
}

/// The cache's upkeep: a sweep now and every [every], by the limits as they
/// are at each sweep.
class ToolImageUpkeep {
  ToolImageUpkeep._(this._sweep, Duration every) {
    _sweep();
    _timer = Timer.periodic(every, (_) => _sweep());
  }

  final void Function() _sweep;
  late final Timer _timer;

  bool get isActive => _timer.isActive;

  void sweepNow() => _sweep();

  void cancel() => _timer.cancel();
}

/// Points the tool-image cache at `<data>/tool-images` and keeps it bounded by
/// [limits], read again at every sweep. [sweepLegacy] also drains the old
/// folder in the system temp, which every server on the machine shared.
ToolImageUpkeep startToolImageUpkeep(
  String dataDirectory, {
  Duration every = const Duration(days: 1),
  bool sweepLegacy = true,
  ToolImageLimits Function()? limits,
}) {
  final cache = Directory(p.join(dataDirectory, kToolImageFolderName));
  useToolImageDirectory(cache.path);
  return ToolImageUpkeep._(() {
    final now = limits?.call() ?? const ToolImageLimits();
    sweepToolImages(cache, maxAge: now.maxAge, maxBytes: now.maxBytes);
    if (sweepLegacy) sweepToolImages(legacyToolImageDirectory);
  }, every);
}

/// How many files the cache holds and their size.
typedef ToolImageCacheReading = ({int files, int bytes});

ToolImageCacheReading readToolImageCache(Directory cache) {
  var files = 0;
  var bytes = 0;
  try {
    for (final entry in cache.listSync(followLinks: false)) {
      if (entry is! File) continue;
      files++;
      bytes += entry.lengthSync();
    }
  } on FileSystemException {
    // Not written yet, or gone: what was counted stands.
  }
  return (files: files, bytes: bytes);
}

/// Deletes every file in the cache; returns how many went. One held open by
/// a viewer stays for the next sweep.
int clearToolImageCache(Directory cache) {
  var removed = 0;
  try {
    for (final entry in cache.listSync(followLinks: false)) {
      if (entry is! File) continue;
      try {
        entry.deleteSync();
        removed++;
      } on FileSystemException {
        // Held open; the sweep takes it later.
      }
    }
  } on FileSystemException {
    return removed;
  }
  return removed;
}
