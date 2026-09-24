import 'dart:typed_data';

import '../pty/pty.dart';
import 'output_backlog.dart';
import 'session_lifecycle.dart';

/// One session's bytes beyond this process's memory. Written from the same
/// place as the ring and bounded to the same size, which is what lets a
/// restarted host answer `attach since N` without growing without limit.
abstract class SessionRecorder {
  /// One chunk, exactly as it went into the ring.
  void record(Uint8List bytes);

  /// The session's grid changed after [offset] bytes of output: what lets a
  /// capture be replayed at the sizes it was written at.
  void resized(int offset, int columns, int rows);

  /// The session ended, and how — written when the child was reaped.
  void ended(SessionLifecycle lifecycle);

  /// Releases the handle. Forgetting the record itself is the store's job.
  void close();
}

/// One session read back from a record the last host left.
class RestoredSession {
  const RestoredSession({
    required this.id,
    required this.request,
    required this.startedAt,
    required this.lifecycle,
    required this.wasRunning,
    required this.backlog,
  });

  final String id;
  final PtySpawnRequest request;
  final DateTime startedAt;

  /// What the record can say about how it ended, including that it cannot.
  final SessionLifecycle lifecycle;

  /// Whether the record said it was still running when its host stopped: the
  /// process did not survive, the output did, and they deserve different words.
  final bool wasRunning;

  /// Seeded with the absolute total reached, so `attach since N` answers exactly.
  final OutputBacklog backlog;
}

/// Where sessions are kept beyond this process. Declared here and implemented
/// in `serve/`, so the domain never imports `dart:io`.
abstract class SessionBacklogStore {
  /// Opens the record for a session starting now.
  SessionRecorder open(String id, PtySpawnRequest request, DateTime startedAt);

  /// Everything the last host left behind, oldest first.
  List<RestoredSession> restore();

  /// Drops a session's record for good.
  void forget(String id);
}
