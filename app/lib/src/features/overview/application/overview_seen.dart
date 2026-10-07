import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_core/logging.dart';
import 'package:path/path.dart' as p;

import 'overview_prefs.dart';

/// **When the owner last looked at each session**, on this device: the
/// moment its peek last showed it. Kept beside the Overview's other choices.
class OverviewSeenController extends Notifier<Map<String, DateTime>> {
  static final _log = AppLogger.named('overview.seen');
  var _touched = false;

  @override
  Map<String, DateTime> build() {
    unawaited(_load());
    return const {};
  }

  Future<File> _file() async => File(
    p.join(
      (await ref.read(overviewPrefsDirectoryProvider)()).path,
      'overview_seen.json',
    ),
  );

  Future<void> _load() async {
    try {
      final json = jsonDecode(await (await _file()).readAsString());
      if (json is! Map) return;
      final kept = <String, DateTime>{
        for (final MapEntry(:key, :value) in json.entries)
          if (key is String && value is String)
            if (DateTime.tryParse(value) case final at?) key: at.toUtc(),
      };
      // A look taken while the file was read wins over what it held.
      if (ref.mounted) state = {...kept, if (_touched) ...state};
    } on Object {
      // Nothing kept yet, or unreadable: nothing has been looked at.
    }
  }

  /// [sessionId] was looked at, at [at].
  void markSeen(String sessionId, DateTime at) {
    if (!ref.mounted) return;
    _touched = true;
    state = {...state, sessionId: at.toUtc()};
    unawaited(_write());
  }

  Future<void> _write() async {
    final seen = state;
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          for (final MapEntry(:key, :value) in seen.entries)
            key: value.toIso8601String(),
        }),
        flush: true,
      );
    } on Object catch (e) {
      _log.warning('Keeping when sessions were looked at failed: $e');
    }
  }
}

final overviewSeenProvider =
    NotifierProvider<OverviewSeenController, Map<String, DateTime>>(
      OverviewSeenController.new,
    );

/// How many of [times] came after [seen]; null when the session was never
/// looked at here, which is not "nothing new".
int? newSince(DateTime? seen, Iterable<DateTime> times) =>
    seen == null ? null : times.where((t) => t.isAfter(seen)).length;
