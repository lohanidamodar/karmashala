import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/clock_provider.dart';
import 'session_status_providers.dart';

/// How long a turn may run on after Stop before the chat offers to end the
/// session instead.
const Duration kStopEscalationAfter = Duration(seconds: 5);

/// **Whether [String]'s own turn runs now**, as the server's status reports
/// it: what offers Stop and makes Esc stop. Background work alone is not a
/// turn — Esc does not stop it, and at the prompt a stray Esc clears input.
final sessionTurnWorkingProvider = Provider.autoDispose.family<bool, String>(
  (ref, sessionId) => ref.watch(
    agentSessionStatusProvider(sessionId).select(
      (status) =>
          status.asData?.value.turnStatus == AgentActivityStatus.working,
    ),
  ),
);

/// One session's Stop: when it was pressed, whether the turn ran on past
/// [kStopEscalationAfter], and whether it has ended since.
@immutable
class TurnStop {
  const TurnStop({
    required this.pressedAt,
    this.stillWorking = false,
    this.settled = false,
  });

  final DateTime pressedAt;

  /// The turn outlived the grace: the next Stop ends the session.
  final bool stillWorking;

  /// The turn ended after the press: it is drawn as stopped.
  final bool settled;

  TurnStop copyWith({bool? stillWorking, bool? settled}) => TurnStop(
    pressedAt: pressedAt,
    stillWorking: stillWorking ?? this.stillWorking,
    settled: settled ?? this.settled,
  );

  @override
  bool operator ==(Object other) =>
      other is TurnStop &&
      other.pressedAt == pressedAt &&
      other.stillWorking == stillWorking &&
      other.settled == settled;

  @override
  int get hashCode => Object.hash(pressedAt, stillWorking, settled);
}

/// **Every Stop pressed in a chat, by session.** Watches the server's status
/// after each press: a turn still running after [kStopEscalationAfter] is
/// marked [TurnStop.stillWorking]; one that ends is marked settled, and the
/// mark goes when the next turn starts.
class TurnStops extends Notifier<Map<String, TurnStop>> {
  final _timers = <String, Timer>{};
  final _watches = <String, ProviderSubscription<bool>>{};

  @override
  Map<String, TurnStop> build() {
    ref.onDispose(() {
      for (final timer in _timers.values) {
        timer.cancel();
      }
      for (final watch in _watches.values) {
        watch.close();
      }
      _timers.clear();
      _watches.clear();
    });
    return const {};
  }

  /// [sessionId]'s Stop was pressed: its turn is watched from now.
  void pressed(String sessionId) {
    state = {
      ...state,
      sessionId: TurnStop(pressedAt: ref.read(clockProvider).nowUtc()),
    };
    _timers.remove(sessionId)?.cancel();
    _timers[sessionId] = Timer(kStopEscalationAfter, () {
      _timers.remove(sessionId);
      final stop = state[sessionId];
      if (stop == null || stop.settled) return;
      if (!ref.read(sessionTurnWorkingProvider(sessionId))) return;
      state = {...state, sessionId: stop.copyWith(stillWorking: true)};
    });
    _watches[sessionId] ??= ref.listen<bool>(
      sessionTurnWorkingProvider(sessionId),
      (_, working) => _moved(sessionId, working: working),
    );
  }

  void _moved(String sessionId, {required bool working}) {
    final stop = state[sessionId];
    if (stop == null) return;
    if (!working && !stop.settled) {
      _timers.remove(sessionId)?.cancel();
      state = {
        ...state,
        sessionId: stop.copyWith(settled: true, stillWorking: false),
      };
    } else if (working && stop.settled) {
      // The next turn: the mark belonged to the one before.
      _watches.remove(sessionId)?.close();
      state = {...state}..remove(sessionId);
    }
  }
}

final turnStopsProvider = NotifierProvider<TurnStops, Map<String, TurnStop>>(
  TurnStops.new,
);

/// Whether [String]'s turn ran on past [kStopEscalationAfter] after Stop and
/// still runs: the chat offers to end the session.
final stopEscalatedProvider = Provider.autoDispose.family<bool, String>(
  (ref, sessionId) =>
      ref.watch(
            turnStopsProvider.select((stops) => stops[sessionId]?.stillWorking),
          ) ==
          true &&
      ref.watch(sessionTurnWorkingProvider(sessionId)),
);
