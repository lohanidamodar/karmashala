import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../cli_detection/application/cli_detection_providers.dart';
import '../../cli_detection/data/cli_transcript_reader.dart';
import '../../cli_detection/domain/imported_session.dart';
import '../../git/application/changes_providers.dart';
import '../../repositories/domain/repository.dart';
import '../domain/session.dart';
import '../domain/session_event.dart';
import 'session_engine_provider.dart';
import 'session_providers.dart';
import 'session_signals.dart';

/// `sessionsRevisionProvider` moved to `session_signals.dart` when it gained a
/// narrow half; re-exported so the twenty-odd files that import it from here
/// keep working.
export 'session_signals.dart';

/// Sessions belonging to the currently selected repository.
///
/// Draws names and statuses, so it says so. It is *not* woken by a permission
/// mode being set on a row, nor by a project rescan that touched no session.
final sessionsForSelectedRepositoryProvider =
    Provider.autoDispose<List<Session>>((ref) {
      ref.watchSessionKinds(const {
        SessionChangeKind.membership,
        SessionChangeKind.title,
        SessionChangeKind.status,
        SessionChangeKind.placement,
      });
      final repoId = ref.watch(selectedRepositoryIdProvider);
      if (repoId == null) return const [];
      return ref.read(sessionDaoProvider).getByRepository(repoId);
    });

/// Imported CLI sessions belonging to the selected repository.
///
/// Placement is on the list because a *native* row learning its conversation
/// id hides the imported record for that conversation (`ImportedSessionDao`),
/// so this list shortens on a fact that is nothing to do with its own rows.
final importedSessionsForSelectedRepositoryProvider =
    Provider.autoDispose<List<ImportedSession>>((ref) {
      ref.watchSessionKinds(const {
        SessionChangeKind.membership,
        SessionChangeKind.title,
        SessionChangeKind.placement,
      });
      final repoId = ref.watch(selectedRepositoryIdProvider);
      if (repoId == null) return const [];
      return ref.read(importedSessionDaoProvider).getByRepository(repoId);
    });

/// The native session whose transcript is shown, or `null`.
class SelectedSessionController extends Notifier<String?> {
  @override
  String? build() => null;
  void select(String? id) => state = id;
}

final selectedSessionIdProvider =
    NotifierProvider<SelectedSessionController, String?>(
      SelectedSessionController.new,
    );

/// The full transcript of an imported CLI session, parsed from its store file
/// and **kept live**: the file is polled, so a session running elsewhere (e.g.
/// the same CLI session open in an external terminal) streams into the app.
final importedTranscriptProvider = StreamProvider.autoDispose
    .family<List<TranscriptMessage>, String>((ref, sessionId) async* {
      final session = ref.read(importedSessionDaoProvider).getById(sessionId);
      if (session == null) {
        yield const [];
        return;
      }
      final file = File(session.filePath);
      DateTime? lastModified;
      var firstRead = true;
      while (true) {
        DateTime? modified;
        try {
          // `stat()` rather than `existsSync()` + `lastModifiedSync()`: this
          // runs on the UI isolate, and the transcripts it polls can live on a
          // `\\wsl.localhost\...` share where the synchronous pair measures
          // 1.19 ms against 0.07 ms locally. One file every two seconds is not
          // the hitch Loop 90 was chasing, but there is no reason to block for
          // it — the asynchronous form runs on `dart:io`'s thread pool.
          final stat = await file.stat();
          modified = stat.type == FileSystemEntityType.notFound
              ? null
              : stat.modified;
        } catch (_) {
          modified = null;
        }
        if (firstRead || modified != lastModified) {
          firstRead = false;
          lastModified = modified;
          yield await readCliTranscript(session.filePath, session.cli);
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    });

/// The imported session whose detail is shown, or `null`.
class SelectedImportedSessionController extends Notifier<String?> {
  @override
  String? build() => null;
  void select(String? id) => state = id;
}

final selectedImportedSessionIdProvider =
    NotifierProvider<SelectedImportedSessionController, String?>(
      SelectedImportedSessionController.new,
    );

/// Repositories the selected session spans (primary first). Refreshes when
/// *that* session's checkouts are attached or detached — not when any other
/// session moves.
final selectedSessionRepositoriesProvider =
    Provider.autoDispose<List<Repository>>((ref) {
      final id = ref.watch(selectedSessionIdProvider);
      if (id == null) return const [];
      ref.watchSession(id);
      return ref.read(sessionRepositoriesServiceProvider).forSession(id);
    });

/// Live transcript for the selected session: the persisted event history,
/// refreshed whenever the engine appends a new event to an active session.
final sessionTranscriptProvider =
    StreamProvider.autoDispose<List<SessionEvent>>((ref) async* {
      final id = ref.watch(selectedSessionIdProvider);
      if (id == null) {
        yield const [];
        return;
      }
      // Re-subscribe when *this* session is (re)started, so a freshly
      // relaunched agent's live stream is picked up. Another session starting
      // used to tear this stream down and rebuild it from the event log.
      ref.watchSession(id);
      final eventDao = ref.read(sessionEventDaoProvider);
      final engine = ref.read(sessionEngineProvider);

      yield eventDao.listForSession(id);
      final live = engine.watch(id);
      if (live != null) {
        await for (final _ in live) {
          yield eventDao.listForSession(id);
        }
        // Final read once the run ends (captures the lifecycle event).
        yield eventDao.listForSession(id);
      }
    });
