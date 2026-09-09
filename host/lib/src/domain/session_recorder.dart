import 'dart:typed_data';

import '../pty/pty.dart';
import 'output_backlog.dart';
import 'session_lifecycle.dart';

/// Where one session's bytes are kept beyond this process's memory.
///
/// The ring is the session's *memory*; this is its *record*. They are written
/// from the same place and bounded to the same size, which is what makes a
/// restarted host able to answer `attach since N` at all — and what stops the
/// answer growing without limit.
abstract class SessionRecorder {
  /// One chunk, exactly as it went into the ring.
  void record(Uint8List bytes);

  /// The session ended, and how. Written when the child was reaped, which is an
  /// event the host already observes.
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

  /// What the record is able to say about how it ended — including saying it
  /// cannot, which is the case a lost session takes.
  final SessionLifecycle lifecycle;

  /// Whether the record said this session was still **running** when the host
  /// that owned it stopped. Its process did not survive; its output did. The
  /// two deserve different sentences and this is the difference.
  final bool wasRunning;

  /// Seeded with the absolute total the session reached, so `attach since N`
  /// answers exactly — including telling a client how much was discarded.
  final OutputBacklog backlog;
}

/// Where sessions are kept beyond this process.
///
/// Declared in the domain and implemented in `serve/` so nothing here has to
/// import `dart:io` to have a backlog that survives a restart, and so a test
/// can hand the registry a store with no filesystem behind it.
abstract class SessionBacklogStore {
  /// Opens the record for a session starting now.
  SessionRecorder open(String id, PtySpawnRequest request, DateTime startedAt);

  /// Everything the last host left behind, oldest first.
  List<RestoredSession> restore();

  /// Drops a session's record for good.
  void forget(String id);
}
