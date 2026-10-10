import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_core/logging.dart';
import 'package:path/path.dart' as p;

import '../../../core/paths/app_support_directory.dart';

/// Where [UsageTabPrefsStore] keeps its file; a test points it at a folder of
/// its own.
final usageTabPrefsDirectoryProvider = Provider<Future<Directory> Function()>(
  (ref) => appSupportDirectory,
);

/// **The Usage tab's choices on this device** — which account, which range —
/// in a file of their own, so the tab opens where it was left. Per device,
/// like the session lists': another window's choice is not this one's.
class UsageTabPrefsStore {
  UsageTabPrefsStore(this._directory);

  static final _log = AppLogger.named('usage.tabPrefs');

  final Future<Directory> Function() _directory;

  Future<File> _file() async =>
      File(p.join((await _directory()).path, 'usage_tab.json'));

  /// What was kept, or null when nothing was or it cannot be read.
  Future<Map<String, Object?>?> load() async {
    try {
      final json = jsonDecode(await (await _file()).readAsString());
      return json is Map<String, Object?> ? json : null;
    } on Object {
      return null;
    }
  }

  /// The write in flight: the next waits for it, so quick changes never
  /// write the one file at once.
  Future<void> _writing = Future<void>.value();

  /// Keeps [json]; settles once it, and every write before it, is on disk.
  Future<void> save(Map<String, Object?> json) =>
      _writing = _writing.then((_) async {
        try {
          final file = await _file();
          await file.parent.create(recursive: true);
          await file.writeAsString(jsonEncode(json), flush: true);
        } on Object catch (e) {
          _log.warning('Keeping the Usage tab choices failed: $e');
        }
      });
}

final usageTabPrefsStoreProvider = Provider<UsageTabPrefsStore>(
  (ref) => UsageTabPrefsStore(ref.watch(usageTabPrefsDirectoryProvider)),
);
