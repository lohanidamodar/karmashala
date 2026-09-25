import 'dart:async';

import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_source.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/relayed_agent_hook.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_store/database.dart';

import 'fixtures.dart';

/// A host that answers from memory: each [open] is one link, whose events the
/// test pushes and whose end is the host going away.
///
/// Given a [store], it is also the daemon writing to it, as `serve` does: the
/// snapshot and the unheld rows on each open, then each event, every write
/// told to the app as a session change. Without one it writes nothing.
class FakeHostLifecycle implements HostLifecycleSource {
  FakeHostLifecycle([AppDatabase? store])
    : _keeper = store == null ? null : HostedSessionStatusKeeper(store) {
    _keeper?.changes.listen((change) {
      final link = changeLinks.lastOrNull;
      if (link != null && !link.isClosed) {
        link.add((sessionId: change.sessionId, status: change.to.name));
      }
    });
  }

  final HostedSessionStatusKeeper? _keeper;
  bool listening = true;
  List<SessionFacts> snapshot = const [];
  List<RelayedAgentHook> hookSnapshot = const [];
  final links = <StreamController<SessionLifecycleEvent>>[];
  final hookLinks = <StreamController<RelayedAgentHook>>[];
  final changeLinks = <StreamController<HostSessionChange>>[];

  /// What each open said the app runs itself.
  final runByClient = <List<String>>[];

  /// The hold ids the app released, in order.
  final replies = <int>[];

  StreamController<SessionLifecycleEvent> get link => links.last;
  StreamController<RelayedAgentHook> get hookLink => hookLinks.last;
  StreamController<HostSessionChange> get changeLink => changeLinks.last;

  @override
  Future<HostLifecycleFeed?> open({List<String> runByClient = const []}) async {
    this.runByClient.add(runByClient);
    if (!listening) return null;
    final link = StreamController<SessionLifecycleEvent>();
    final hooks = StreamController<RelayedAgentHook>();
    final changes = StreamController<HostSessionChange>();
    links.add(link);
    hookLinks.add(hooks);
    changeLinks.add(changes);
    final keeper = _keeper;
    if (keeper != null) {
      keeper.applySnapshot(snapshot);
      keeper.markUnheld(
        heldHostSessionIds: {for (final f in snapshot) f.hostSessionId},
        runByClient: runByClient.toSet(),
      );
    }
    return HostLifecycleFeed(
      snapshot: List.of(snapshot),
      events: link.stream.map((event) {
        keeper?.applyEvent(event);
        return event;
      }),
      hookSnapshot: List.of(hookSnapshot),
      hooks: hooks.stream,
      replyHook: replies.add,
      sessionChanges: changes.stream,
      close: () async {
        if (!link.isClosed) await link.close();
        if (!hooks.isClosed) await hooks.close();
        if (!changes.isClosed) await changes.close();
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
