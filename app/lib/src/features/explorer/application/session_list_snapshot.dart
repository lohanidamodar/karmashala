import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_ui/rows.dart' show needsYouWord;
import 'package:path/path.dart' as p;

import '../../../core/data/data_providers.dart';
import '../../agents/data/agents_data.dart';
import '../../sessions/application/session_signals.dart';
import '../../sessions/application/session_status_providers.dart';
import 'agent_state_providers.dart';
import 'agent_states.dart';
import 'workspace_session_entry.dart';

/// Bumped when a stored field changes meaning; an older file is then ignored.
const int kSessionSnapshotFormat = 1;

/// The most often a snapshot is written (decision 9).
const Duration kSessionSnapshotInterval = Duration(seconds: 5);

/// How long opening a remote server waits for its first answer when there is
/// a last list to show instead; the dial goes on after it.
const Duration kStaleListFirstDialWait = Duration(milliseconds: 1500);

/// Rows kept of a group that folds; its header still says the whole count.
const int kSnapshotFoldedRows = 50;

/// One row of the last session list, as the Sessions tab drew it.
@immutable
class SnapshotRow {
  const SnapshotRow({
    required this.id,
    required this.title,
    this.agentId,
    this.projectName,
    this.waitWord,
    this.activityAt,
  });

  final String id;
  final String title;
  final String? agentId;
  final String? projectName;

  /// What a needs-you row waited on ("approve", "question", "waiting").
  final String? waitWord;

  /// Null for a row nothing dated.
  final DateTime? activityAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'agentId': ?agentId,
    'projectName': ?projectName,
    'waitWord': ?waitWord,
    'activityAt': ?activityAt?.toUtc().toIso8601String(),
  };

  static SnapshotRow? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final title = json['title'];
    if (id is! String || title is! String) return null;
    String? text(String key) =>
        json[key] is String ? json[key] as String : null;
    final at = text('activityAt');
    return SnapshotRow(
      id: id,
      title: title,
      agentId: text('agentId'),
      projectName: text('projectName'),
      waitWord: text('waitWord'),
      activityAt: at == null ? null : DateTime.tryParse(at),
    );
  }
}

/// One state's rows. [total] is the group's length when it was saved, which
/// a folded group's [rows] may fall short of.
@immutable
class SnapshotGroup {
  const SnapshotGroup(this.state, this.total, this.rows);

  final AgentState state;
  final int total;
  final List<SnapshotRow> rows;

  Map<String, Object?> toJson() => {
    'state': state.name,
    'total': total,
    'rows': [for (final row in rows) row.toJson()],
  };

  static SnapshotGroup? fromJson(Object? json) {
    if (json is! Map) return null;
    final state = AgentState.values.asNameMap()[json['state']];
    final rows = json['rows'];
    if (state == null || rows is! List) return null;
    final parsed = [for (final row in rows) ?SnapshotRow.fromJson(row)];
    final total = json['total'];
    return SnapshotGroup(
      state,
      total is int ? math.max(total, parsed.length) : parsed.length,
      List.unmodifiable(parsed),
    );
  }
}

/// **The last session list this device saw of one server** (decision 9):
/// drawn stale, and acted on never, until the server answers.
@immutable
class SessionListSnapshot {
  const SessionListSnapshot({required this.savedAt, required this.groups});

  final DateTime savedAt;

  /// In [AgentState] order; empty groups are left out.
  final List<SnapshotGroup> groups;

  int get needsYouCount => [
    for (final group in groups)
      if (group.state == AgentState.needsYou) group.total,
  ].fold(0, (a, b) => a + b);

  List<Object?> _groupsJson() => [for (final group in groups) group.toJson()];

  String encode() => jsonEncode({
    'format': kSessionSnapshotFormat,
    'savedAt': savedAt.toUtc().toIso8601String(),
    'groups': _groupsJson(),
  });

  /// Null for anything unreadable or of another format.
  static SessionListSnapshot? decode(String source) {
    final Object? json;
    try {
      json = jsonDecode(source);
    } on FormatException {
      return null;
    }
    if (json is! Map || json['format'] != kSessionSnapshotFormat) return null;
    final savedAt = json['savedAt'];
    final groups = json['groups'];
    if (savedAt is! String || groups is! List) return null;
    final at = DateTime.tryParse(savedAt);
    if (at == null) return null;
    final parsed = [for (final group in groups) ?SnapshotGroup.fromJson(group)]
      ..sort((a, b) => a.state.index.compareTo(b.state.index));
    return SessionListSnapshot(savedAt: at, groups: List.unmodifiable(parsed));
  }
}

/// Reads and writes `<app support>/machines/<hostId>/sessions-snapshot.json`
/// for the one remote server a session is open on. Writes at most every
/// [kSessionSnapshotInterval], only when the list differs from the last
/// write, and at once when the app is paused.
class SessionListSnapshotStore {
  SessionListSnapshotStore._(this.file, this.loaded, this._log) {
    _lifecycle = AppLifecycleListener(onPause: () => unawaited(flush()));
  }

  static const fileName = 'sessions-snapshot.json';

  /// The store for the server whose per-machine folder is [machineDirectory],
  /// with what it last saved there, if anything readable.
  static Future<SessionListSnapshotStore> open(
    Directory machineDirectory, {
    AppLogger? logger,
  }) async {
    final log = logger ?? AppLogger.named('session_snapshot');
    final file = File(p.join(machineDirectory.path, fileName));
    SessionListSnapshot? loaded;
    try {
      if (await file.exists()) {
        loaded = SessionListSnapshot.decode(await file.readAsString());
      }
    } on FileSystemException catch (error) {
      log.warning('The last session list could not be read: $error');
    }
    return SessionListSnapshotStore._(file, loaded, log);
  }

  /// Deletes what was saved for [hostId] — on Forget of that machine.
  static Future<void> deleteFor(Directory support, String hostId) async {
    final file = File(p.join(support.path, 'machines', hostId, fileName));
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Already gone.
    }
  }

  final File file;

  /// What was on disk when the session opened: the stale list.
  final SessionListSnapshot? loaded;

  final AppLogger _log;
  late final AppLifecycleListener _lifecycle;
  SessionListSnapshot? _pending;
  String? _lastGroups;
  DateTime? _lastWriteAt;
  Timer? _timer;
  Future<void> _writing = Future<void>.value();
  var _closed = false;

  /// Takes [snapshot] as the list now, to be written within the interval.
  void record(SessionListSnapshot snapshot) {
    if (_closed) return;
    if (jsonEncode(snapshot._groupsJson()) == _lastGroups) {
      _pending = null;
      return;
    }
    _pending = snapshot;
    if (_timer != null) return;
    final since = _lastWriteAt == null
        ? kSessionSnapshotInterval
        : DateTime.now().difference(_lastWriteAt!);
    final wait = since >= kSessionSnapshotInterval
        ? Duration.zero
        : kSessionSnapshotInterval - since;
    _timer = Timer(wait, () => unawaited(flush()));
  }

  /// Writes what is pending now.
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    final snapshot = _pending;
    _pending = null;
    if (snapshot == null || _closed) return _writing;
    final groups = jsonEncode(snapshot._groupsJson());
    if (groups == _lastGroups) return _writing;
    _lastGroups = groups;
    _lastWriteAt = DateTime.now();
    return _writing = _writing.then((_) => _write(snapshot.encode()));
  }

  Future<void> _write(String contents) async {
    try {
      await file.parent.create(recursive: true);
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(contents, flush: true);
      await temp.rename(file.path);
    } on FileSystemException catch (error) {
      _log.warning('The session list could not be saved: $error');
    }
  }

  /// This machine was forgotten: nothing more is written, and the file goes.
  Future<void> discard() async {
    _closed = true;
    _timer?.cancel();
    _timer = null;
    _pending = null;
    await _writing;
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Already gone.
    }
  }

  /// The session is closing: what is pending is written, then nothing more.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (!_closed) unawaited(flush());
    _closed = true;
    _timer?.cancel();
    _lifecycle.dispose();
  }

  var _disposed = false;
}

/// The open session's snapshot store; null for this machine's own server,
/// which is always there.
final sessionListSnapshotStoreProvider = Provider<SessionListSnapshotStore?>(
  (ref) => null,
);

/// Whether the server has said what the sessions are.
final sessionsPrimedProvider = Provider<bool>((ref) {
  final sessions = ref.watch(dataClientProvider).sessions;
  if (sessions.isPrimed) return true;
  final revisions = ref.read(sessionsRevisionProvider.notifier);
  var heard = false;
  final changes = sessions.changes.listen((_) {
    if (heard || !sessions.isPrimed) return;
    heard = true;
    ref.invalidateSelf();
    // The first answer names no row it moved, so nothing would read the
    // list again: every session watcher is woken once.
    revisions.bump();
  });
  ref.onDispose(() => unawaited(changes.cancel()));
  return false;
});

/// The last list, while the server has not answered yet; null once it has,
/// or when nothing was saved.
final staleSessionListProvider = Provider<SessionListSnapshot?>((ref) {
  final store = ref.watch(sessionListSnapshotStoreProvider);
  if (store == null || ref.watch(sessionsPrimedProvider)) return null;
  return store.loaded;
});

/// The needs-you count the stale list shows; null while the list is live.
final staleNeedsYouCountProvider = Provider<int?>(
  (ref) => ref.watch(staleSessionListProvider)?.needsYouCount,
);

/// Records the Sessions tab's list while it is live and on screen. Watched by
/// the page, so nothing is computed where the list is not drawn.
final sessionListSnapshotWriterProvider = Provider.autoDispose<void>((ref) {
  final store = ref.watch(sessionListSnapshotStoreProvider);
  if (store == null) return;
  void record() {
    if (!ref.read(sessionsPrimedProvider)) return;
    store.record(_snapshotOf(ref, ref.read(agentStateGroupsProvider)));
  }

  ref.listen(agentStateGroupsProvider, (_, _) => record());
  ref.listen(sessionsPrimedProvider, (_, _) => record(), fireImmediately: true);
});

SessionListSnapshot _snapshotOf(Ref ref, List<AgentStateGroup> groups) {
  final statusOf = ref.read(sessionStatusLookupProvider);
  final installations = ref.read(agentInstallationsDataProvider);
  SnapshotRow row(WorkspaceSessionEntry entry, AgentState state) {
    final native = entry.native;
    return SnapshotRow(
      id: entry.id,
      title: entry.title,
      agentId:
          entry.imported?.cli ??
          (native == null
              ? null
              : installations.getById(native.agentInstallationId)?.agentId),
      projectName: entry.projectName,
      waitWord: state == AgentState.needsYou
          ? needsYouWord(statusOf(entry.id)?.waiting)
          : null,
      activityAt: native != null || entry.imported != null
          ? entry.activityAt
          : null,
    );
  }

  return SessionListSnapshot(
    savedAt: DateTime.now().toUtc(),
    groups: List.unmodifiable([
      for (final group in groups)
        if (!group.isEmpty)
          SnapshotGroup(
            group.state,
            group.length,
            List.unmodifiable([
              for (final entry in group.entries.take(
                group.state.fold == AgentStateFold.open
                    ? group.length
                    : kSnapshotFoldedRows,
              ))
                row(entry, group.state),
            ]),
          ),
    ]),
  );
}
