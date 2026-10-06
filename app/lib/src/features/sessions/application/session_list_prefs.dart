import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_core/logging.dart';
import 'package:path/path.dart' as p;

import '../../../core/paths/app_support_directory.dart';

/// How this device shows its session lists: whether archived and working
/// sessions are listed, and which parents' sub-sessions the person folded or
/// opened. Kept per device, in a file of its own: the settings are the
/// server's, and one window's tidy-up should not rearrange another's lists.
class SessionListPrefs {
  const SessionListPrefs({
    this.showArchived = false,
    this.hideWorking = false,
    this.folds = const {},
  });

  final bool showArchived;

  /// "Hide while working": sessions busy and needing nothing leave the lists.
  final bool hideWorking;

  /// Parent session id → folded, for the parents the person chose for;
  /// absent follows the default.
  final Map<String, bool> folds;

  SessionListPrefs copyWith({
    bool? showArchived,
    bool? hideWorking,
    Map<String, bool>? folds,
  }) => SessionListPrefs(
    showArchived: showArchived ?? this.showArchived,
    hideWorking: hideWorking ?? this.hideWorking,
    folds: folds ?? this.folds,
  );

  Map<String, Object?> toJson() => {
    'showArchived': showArchived,
    'hideWorking': hideWorking,
    'folds': folds,
  };

  static SessionListPrefs fromJson(Object? json) {
    if (json is! Map) return const SessionListPrefs();
    final folds = json['folds'];
    return SessionListPrefs(
      showArchived: json['showArchived'] == true,
      hideWorking: json['hideWorking'] == true,
      folds: {
        if (folds is Map)
          for (final entry in folds.entries)
            if (entry.key is String && entry.value is bool)
              entry.key as String: entry.value as bool,
      },
    );
  }
}

/// Where [SessionListPrefsController] keeps its file; a test points it at a
/// folder of its own.
final sessionListPrefsDirectoryProvider =
    Provider<Future<Directory> Function()>((ref) => appSupportDirectory);

class SessionListPrefsController extends Notifier<SessionListPrefs> {
  static final _log = AppLogger.named('sessions.listPrefs');
  var _touched = false;

  @override
  SessionListPrefs build() {
    unawaited(_load());
    return const SessionListPrefs();
  }

  Future<File> _file() async => File(
    p.join(
      (await ref.read(sessionListPrefsDirectoryProvider)()).path,
      'sessions_device.json',
    ),
  );

  Future<void> _load() async {
    try {
      final kept = SessionListPrefs.fromJson(
        jsonDecode(await (await _file()).readAsString()),
      );
      // A choice made while the file was read wins over what it held.
      if (ref.mounted && !_touched) state = kept;
    } on Object {
      // Nothing kept yet, or unreadable: the defaults stand.
    }
  }

  void setShowArchived(bool show) {
    if (state.showArchived == show) return;
    _set(state.copyWith(showArchived: show));
  }

  void setHideWorking(bool hide) {
    if (state.hideWorking == hide) return;
    _set(state.copyWith(hideWorking: hide));
  }

  /// Folds or opens [parentId]'s sub-sessions.
  void setFolded(String parentId, bool folded) {
    if (state.folds[parentId] == folded) return;
    _set(state.copyWith(folds: {...state.folds, parentId: folded}));
  }

  void _set(SessionListPrefs next) {
    _touched = true;
    state = next;
    unawaited(_write());
  }

  Future<void> _write() async {
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(state.toJson()), flush: true);
    } on Object catch (e) {
      _log.warning('Keeping the session list choices failed: $e');
    }
  }
}

final sessionListPrefsProvider =
    NotifierProvider<SessionListPrefsController, SessionListPrefs>(
      SessionListPrefsController.new,
    );

/// Whether archived sessions are listed on this device.
final showArchivedSessionsProvider = Provider<bool>(
  (ref) => ref.watch(sessionListPrefsProvider.select((p) => p.showArchived)),
);

/// Whether sessions that are working and need nothing leave the lists on this
/// device ("Hide while working").
final hideWorkingSessionsProvider = Provider<bool>(
  (ref) => ref.watch(sessionListPrefsProvider.select((p) => p.hideWorking)),
);
