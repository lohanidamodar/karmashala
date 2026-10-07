import 'package:karmashala_automations/runs.dart' show AutomationRun;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

/// What answers a client's status and inbox requests (`AttentionRequest`:
/// the status list, the inbox and its verbs, what a window is looking at) —
/// the server's attention, set once `serve` has built it. All in memory, so
/// answered at once.
abstract interface class AttentionWork {
  /// Answers [request] for [link] — the asking client's connection, null for
  /// the server itself; throws [DataRefused]. What it changes is told to
  /// every client by the attention itself.
  Object? handle(AttentionRequest<Object?> request, Object? link);

  /// [link] is gone: what it was looking at no longer counts.
  void linkClosed(Object link);

  /// What a client that has just subscribed is told at once: every status
  /// kept, the watch set's reach, and the inbox.
  List<DataChange> greeting();
}

/// What starts and stops automation runs for a client — the server's
/// automations, set once `serve` has started them.
abstract interface class AutomationWork {
  /// Starts automation [id] now, gated like any run; throws [DataRefused]
  /// for one that is not there or cannot be run by hand.
  Future<AutomationRun> runNow(String id);

  /// Stops run [runId]; throws [DataRefused] when it is not live.
  Future<AutomationRun> cancelRun(String runId);
}

/// What runs a session's project checks for a client (`checks.run`) — the
/// server's automations, set once `serve` has started them.
abstract interface class ChecksWork {
  /// Runs [request]'s checks and answers how that ended; throws
  /// [DataRefused] for a session that is not there.
  Future<SessionChecksRun> run(ChecksRun request);
}
