import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_core/logging.dart';
import 'package:path/path.dart' as p;

import '../../../core/util/clock_provider.dart';
import '../../explorer/application/session_context.dart';
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
    } finally {
      if (ref.mounted) ref.read(overviewSeenReadProvider.notifier).done();
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

/// Whether the looks kept on this device have been read: until then a
/// session with none is not taken for one never opened.
class OverviewSeenRead extends Notifier<bool> {
  @override
  bool build() => false;

  void done() => state = true;
}

final overviewSeenReadProvider = NotifierProvider<OverviewSeenRead, bool>(
  OverviewSeenRead.new,
);

/// How many of [times] came after [seen]; null when the session was never
/// looked at here, which is not "nothing new".
int? newSince(DateTime? seen, Iterable<DateTime> times) =>
    seen == null ? null : times.where((t) => t.isAfter(seen)).length;

/// **A session looked at anywhere is seen**: its chat or terminal coming on
/// screen in the workbench marks it as the dashboard's own peek does, and
/// leaving it marks it again, so what came while it was open is seen too.
/// Follows for as long as it is listened to: the desktop listens for the
/// app's life, and the dashboard while it is drawn.
final overviewSeenFollowsScreenProvider = Provider<void>((ref) {
  final seen = ref.read(overviewSeenProvider.notifier);
  void mark(String? id) {
    if (id != null) seen.markSeen(id, ref.read(clockProvider).nowUtc());
  }

  // After this provider is built: one may not change another while it is.
  final first = ref.read(onScreenSessionIdProvider);
  Future.microtask(() {
    if (ref.mounted) mark(first);
  });
  ref.listen(onScreenSessionIdProvider, (before, after) {
    mark(before);
    mark(after);
  });
});
