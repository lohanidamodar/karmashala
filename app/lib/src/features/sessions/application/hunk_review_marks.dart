import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_core/logging.dart';
import 'package:path/path.dart' as p;

import '../../../core/paths/app_support_directory.dart';

/// The hunks the person marked as reviewed (Keep), by session, as hunk keys.
/// Only a mark: nothing about the file changes. Kept per device, in a file of
/// its own, like the session lists' choices.
typedef HunkReviewMarks = Map<String, Set<String>>;

/// Where [HunkReviewMarksController] keeps its file; a test points it at a
/// folder of its own.
final hunkReviewMarksDirectoryProvider = Provider<Future<Directory> Function()>(
  (ref) => appSupportDirectory,
);

class HunkReviewMarksController extends Notifier<HunkReviewMarks> {
  static final _log = AppLogger.named('sessions.hunkMarks');
  var _touched = false;

  /// Settles once what the file held is in [state]; for tests.
  late Future<void> loaded;

  @override
  HunkReviewMarks build() {
    loaded = _load();
    return const {};
  }

  Future<File> _file() async => File(
    p.join(
      (await ref.read(hunkReviewMarksDirectoryProvider)()).path,
      'hunk_reviews_device.json',
    ),
  );

  Future<void> _load() async {
    try {
      final json = jsonDecode(await (await _file()).readAsString());
      if (json is! Map || !ref.mounted || _touched) return;
      state = {
        for (final MapEntry(:key, :value) in json.entries)
          if (key is String && value is List)
            key: {for (final mark in value) ?(mark is String ? mark : null)},
      };
    } on Object {
      // Nothing kept yet, or unreadable: nothing is marked.
    }
  }

  bool kept(String sessionId, String key) =>
      state[sessionId]?.contains(key) ?? false;

  /// Marks [key] reviewed in [sessionId], or takes the mark off.
  void toggle(String sessionId, String key) {
    final marks = {...?state[sessionId]};
    if (!marks.remove(key)) marks.add(key);
    _touched = true;
    state = {...state, sessionId: marks};
    unawaited(_write());
  }

  Future<void> _write() async {
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          for (final MapEntry(:key, :value) in state.entries)
            if (value.isNotEmpty) key: value.toList()..sort(),
        }),
        flush: true,
      );
    } on Object catch (e) {
      _log.warning('Keeping the reviewed hunks failed: $e');
    }
  }
}

final hunkReviewMarksProvider =
    NotifierProvider<HunkReviewMarksController, HunkReviewMarks>(
      HunkReviewMarksController.new,
    );
