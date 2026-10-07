import 'dart:async';

import 'package:agent_cli/descriptors.dart' show ActiveModelReading;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show ActiveModelSource, DataChange, SessionActiveModelChanged;

/// **The model each session's agent last said it is running**, kept here and
/// told to every client as `sessionActiveModelChanged`. An ACP agent says it
/// over its protocol ([report]); a CLI in a terminal says it in its record,
/// read again on its status edges ([refresh]). Nothing here reads a setting:
/// a session nothing has reported for has no model.
class SessionActiveModels {
  SessionActiveModels({
    required this.announce,
    this.readRecord,
    DateTime Function()? now,
  }) : _now = now ?? (() => DateTime.now().toUtc());

  final void Function(SessionActiveModelChanged change) announce;

  /// The newest model [String]'s record names, or null when it names none or
  /// cannot be read.
  Future<ActiveModelReading?> Function(String sessionId)? readRecord;
  final DateTime Function() _now;

  final _held = <String, SessionActiveModelChanged>{};
  final _reading = <String, Future<void>>{};
  final _again = <String>{};

  /// What [sessionId]'s agent last said, or null while it has said nothing.
  SessionActiveModelChanged? of(String sessionId) => _held[sessionId];

  /// [of]'s model id, worded for a text an agent reads.
  String modelWords(String sessionId) =>
      _held[sessionId]?.modelId ?? 'not recorded';

  /// Keeps [modelId] for [sessionId]; clients are told only when it moved,
  /// with the time it was first seen.
  void report(
    String sessionId,
    String modelId, {
    required ActiveModelSource source,
    DateTime? at,
  }) {
    if (_held[sessionId]?.modelId == modelId) return;
    final change = SessionActiveModelChanged(
      sessionId: sessionId,
      modelId: modelId,
      observedAt: (at ?? _now()).toUtc(),
      source: source,
    );
    _held[sessionId] = change;
    announce(change);
  }

  /// Reads [sessionId]'s record again. One read at a time per session, and
  /// one more after it when asked meanwhile, so a burst of edges costs two.
  Future<void> refresh(String sessionId) {
    final running = _reading[sessionId];
    if (running != null) {
      _again.add(sessionId);
      return running;
    }
    final read = _read(sessionId).whenComplete(() {
      _reading.remove(sessionId);
      if (_again.remove(sessionId)) unawaited(refresh(sessionId));
    });
    return _reading[sessionId] = read;
  }

  /// [of], after the read in flight, or a first read when nothing is held.
  Future<SessionActiveModelChanged?> current(String sessionId) async {
    final running = _reading[sessionId];
    if (running != null) {
      await running;
    } else if (_held[sessionId] == null) {
      await refresh(sessionId);
    }
    return _held[sessionId];
  }

  /// Every model held, for a client arriving now.
  List<DataChange> greeting() => List.of(_held.values);

  Future<void> _read(String sessionId) async {
    final reader = readRecord;
    if (reader == null) return;
    final ActiveModelReading? reading;
    try {
      reading = await reader(sessionId);
    } on Object {
      return;
    }
    if (reading == null) return;
    report(
      sessionId,
      reading.modelId,
      source: ActiveModelSource.record,
      at: reading.at,
    );
  }
}
