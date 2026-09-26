import 'dart:async';

import 'package:agent_cli/process.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';

/// The checkpoint index as the server keeps it. A session's chain is asked
/// for once and then kept by what the server says (each capture's answer, and
/// another client's), so a capture per turn costs one request.
///
/// Checkpoints are taken, diffed and restored by the server's recorder: this
/// asks it ([captureNow], [diffOf], [restore], [captureBase]) and never runs
/// git itself. Why a session has none right now ([skipReasonOf]) is the
/// recorder's too, asked once and then kept by what the server says.
class CheckpointsData {
  CheckpointsData(this._client) {
    _listening = _client.evidenceChanges.listen(_onChange);
  }

  final DataClient _client;
  late final StreamSubscription<EvidenceChange> _listening;
  final _sessions = <String, List<Checkpoint>>{};
  final _loading = <String, Future<List<Checkpoint>>>{};
  final _changes = StreamController<String>.broadcast(sync: true);
  Map<String, String>? _skips;
  Future<void>? _loadingSkips;

  /// The session whose checkpoints moved — recorded, relabelled or pruned by
  /// the server's recorder — or whose skip reason did.
  Stream<String> get changes => _changes.stream;

  void _onChange(EvidenceChange change) {
    switch (change) {
      case CheckpointRecorded(:final checkpoint):
        final kept = _sessions[checkpoint.sessionId];
        if (kept != null) {
          _sessions[checkpoint.sessionId] = withCheckpoint(kept, checkpoint);
        }
        _told(checkpoint.sessionId);
      case CheckpointsPruned(:final sessionId):
        _sessions.remove(sessionId);
        _told(sessionId);
      case CheckpointSkipChanged(:final sessionId, :final reason):
        final skips = _skips;
        if (skips != null) {
          reason == null ? skips.remove(sessionId) : skips[sessionId] = reason;
        }
        _told(sessionId);
      default:
        break;
    }
  }

  void _told(String sessionId) {
    if (!_changes.isClosed) _changes.add(sessionId);
  }

  /// Every checkpoint of [sessionId], oldest first.
  Future<List<Checkpoint>> forSession(String sessionId) {
    final kept = _sessions[sessionId];
    if (kept != null) return Future.value(kept);
    return _loading[sessionId] ??= _client
        .send(CheckpointsForSession(sessionId))
        .then((reply) => _sessions[sessionId] ??= reply.value)
        .whenComplete(() {
          _loading.remove(sessionId);
        });
  }

  Future<Checkpoint?> byId(String id) async {
    for (final chain in _sessions.values) {
      for (final c in chain) {
        if (c.id == id) return c;
      }
    }
    return (await _client.send(CheckpointGet(id))).value;
  }

  /// Why [sessionId] has no automatic checkpoints right now, as the server's
  /// recorder last found; null when it is checkpointing (or not yet read —
  /// the first call asks, and [changes] says when the answer lands).
  String? skipReasonOf(String sessionId) {
    final skips = _skips;
    if (skips != null) return skips[sessionId];
    _loadingSkips ??= _client
        .send(const CheckpointSkips())
        .then((reply) {
          _skips = {...reply.value};
          for (final sessionId in reply.value.keys) {
            _told(sessionId);
          }
        })
        .catchError((Object _) {})
        .whenComplete(() => _loadingSkips = null);
    return null;
  }

  /// Captures [sessionId]'s working trees now, through the server's recorder:
  /// the first checkpoint taken, or null when nothing moved or it has no
  /// repository. A labelled one is filed as decided by [decidedBy].
  Future<Checkpoint?> captureNow(
    String sessionId, {
    String? label,
    String? decidedBy,
    String? decidedBySessionId,
  }) async => (await _client.send(
    CheckpointCapture(
      sessionId,
      label: label,
      decidedBy: decidedBy,
      decidedBySessionId: decidedBySessionId,
    ),
  )).value;

  /// The base of a run this app starts: [checkout] recorded under [runId]
  /// even when unchanged.
  Future<Checkpoint?> captureBase(
    EnvironmentPath checkout, {
    required String runId,
    required String label,
  }) async => (await _client.send(
    CheckpointCaptureBase(checkout, runId: runId, label: label),
  )).value;

  /// The unified diff [checkpoint] is, read by the server from git.
  Future<String> diffOf(Checkpoint checkpoint) async =>
      (await _client.send(CheckpointDiff(checkpoint.id))).value;

  /// Puts [checkpoint] back — every file, or only [paths] — at the server.
  /// A tree that moved without [confirm] throws [CheckpointConflict] in the
  /// service's own words; a refusal throws [DataRefused].
  Future<RestoreOutcome> restore(
    Checkpoint checkpoint, {
    bool confirm = false,
    List<String> paths = const [],
  }) async => (await _client.send(
    CheckpointRestore(checkpoint.id, confirm: confirm, paths: paths),
  )).value.outcomeOrThrow;

  Future<void> dispose() async {
    await _listening.cancel();
    await _changes.close();
  }
}

final checkpointsDataProvider = Provider<CheckpointsData>((ref) {
  final data = CheckpointsData(ref.watch(dataClientProvider));
  ref.onDispose(() => unawaited(data.dispose()));
  return data;
});
