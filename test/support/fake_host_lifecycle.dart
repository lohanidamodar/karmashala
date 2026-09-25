import 'dart:async';

import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_source.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';

import 'fixtures.dart';

/// A host that answers from memory: each [open] is one link, whose events the
/// test pushes and whose end is the host going away.
class FakeHostLifecycle implements HostLifecycleSource {
  bool listening = true;
  List<SessionFacts> snapshot = const [];
  final links = <StreamController<SessionLifecycleEvent>>[];

  StreamController<SessionLifecycleEvent> get link => links.last;

  @override
  Future<HostLifecycleFeed?> open() async {
    if (!listening) return null;
    final link = StreamController<SessionLifecycleEvent>();
    links.add(link);
    return HostLifecycleFeed(
      snapshot: List.of(snapshot),
      events: link.stream,
      close: () async {
        if (!link.isClosed) await link.close();
      },
    );
  }
}

DateTime _at(int second) => testTime.add(Duration(seconds: second));

SessionFacts hostFacts(
  String sessionId,
  HostSessionState state, {
  int? exitCode,
  String? reason,
  int second = 1,
}) => SessionFacts(
  hostSessionId: hostSessionIdOf(sessionId),
  state: state,
  exitCode: exitCode,
  reason: reason,
  observedAt: _at(second),
);

SessionLifecycleEvent hostEvent(
  String sessionId,
  SessionLifecycleKind kind, {
  int? exitCode,
  String? reason,
  bool endedByClose = false,
  required int second,
}) => SessionLifecycleEvent(
  hostSessionId: hostSessionIdOf(sessionId),
  kind: kind,
  exitCode: exitCode,
  reason: reason,
  endedByClose: endedByClose,
  observedAt: _at(second),
);
