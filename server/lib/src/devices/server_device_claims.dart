import 'dart:async';

import 'package:karmashala_core/util.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_devices/karmashala_devices.dart';
import 'package:karmashala_session_engine/store.dart' show SessionDao;
import 'package:karmashala_store/database.dart';

/// Who is driving a device, as a `flutter run` asks it (slice 3d's port):
/// the refusal in words when another session holds [deviceId], else null —
/// and the claim taken or renewed for [sessionId].
abstract interface class FlutterDeviceClaims {
  String? claim({
    required String deviceId,
    required String? sessionId,
    required String verb,
  });
}

/// **The one claims registry** on the server's machine (slice 4a): the agent
/// device tools, `flutter run` and — through [DeviceClaimsChanged] — a pane
/// on this machine all answer to it. A holder is named from the sessions
/// store; a session that is over holds nothing (released when its row says
/// so, and on every read); a claim lapses after [DeviceClaims.lapsesAfter]
/// with no call from its holder, and reading a device renews its holder's
/// claim. Every change is told to every client.
class ServerDeviceClaims implements FlutterDeviceClaims {
  ServerDeviceClaims({
    required AppDatabase database,
    required void Function(List<DataChange> changes) tell,
    Clock clock = const SystemClock(),
    Duration lapsesAfter = kDeviceClaimLapse,
    this.sweepEvery = const Duration(seconds: 15),
  }) : _tell = tell {
    final sessions = SessionDao(database);
    registry = DeviceClaims(
      clock: clock,
      lapsesAfter: lapsesAfter,
      holder: (sessionId) {
        final session = sessions.getById(sessionId);
        if (session == null || session.isOver) return null;
        return session.title;
      },
    )..onChanged = _changed;
  }

  final void Function(List<DataChange> changes) _tell;

  /// How often a lapse is looked for, so a client hears of one without a
  /// device call to prune it.
  final Duration sweepEvery;

  late final DeviceClaims registry;
  Timer? _sweeper;

  /// Every hold as the wire carries it.
  List<DeviceHold> get holds => [
    for (final claim in registry.held)
      DeviceHold(
        deviceId: claim.deviceId,
        holderSessionId: claim.holderSessionId,
        holderTitle: claim.holderTitle,
        takenAt: claim.takenAt,
        lastCallAt: claim.lastCallAt,
        lastVerb: claim.lastVerb,
        calls: claim.calls,
      ),
  ];

  void _changed() => _tell([DeviceClaimsChanged(holds)]);

  /// What a client that subscribes is told on arrival: the claims standing.
  List<DataChange> greeting() =>
      registry.held.isEmpty ? const [] : [DeviceClaimsChanged(holds)];

  /// Releases what an ended session held, from the rows the server tells.
  /// Deferred a turn: a claim's own change must not be told inside the batch
  /// that ended the session, ahead of it and under a newer revision.
  void watch(List<DataChange> changes) {
    final over = <String>{
      for (final change in changes)
        if (change case SessionRowChanged(:final session) when session.isOver)
          session.id
        else if (change case SessionRowRemoved(:final id))
          id,
    };
    if (over.isEmpty) return;
    scheduleMicrotask(() => over.forEach(registry.release));
  }

  /// Looks for lapses every [sweepEvery]. Idempotent.
  void start() => _sweeper ??= Timer.periodic(sweepEvery, (_) {
    registry.sweep();
  });

  @override
  String? claim({
    required String deviceId,
    required String? sessionId,
    required String verb,
  }) {
    try {
      registry.claim(deviceId: deviceId, sessionId: sessionId, verb: verb);
      return null;
    } on DeviceBusy catch (busy) {
      return busy.message;
    }
  }

  void close() {
    _sweeper?.cancel();
    _sweeper = null;
  }
}
