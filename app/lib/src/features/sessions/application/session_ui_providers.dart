import 'dart:io';

import 'package:riverpod/riverpod.dart';

import '../../cli_detection/application/cli_detection_providers.dart';
import 'package:agent_cli/read.dart';
import '../../git/application/changes_providers.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/events.dart';
import 'session_engine_provider.dart';
import 'session_providers.dart';
import 'session_signals.dart';

/// `sessionsRevisionProvider` moved to `session_signals.dart` when it gained a
/// narrow half; re-exported so the files that import it from here keep working.
export 'session_signals.dart';

/// Sessions belonging to the currently selected repository. Draws names and
/// statuses, so it says so — a permission mode being set wakes nothing.
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

/// Imported CLI sessions for the selected repository. Placement is on the list
/// because a native row learning its id hides the imported record for it.
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

/// The full transcript of an imported CLI session, **kept live**: the file is
/// polled, so a session running elsewhere streams into the app.
final importedTranscriptProvider = StreamProvider.autoDispose
    .family<List<TranscriptMessage>, String>((ref, sessionId) async* {
      final session = ref.read(importedSessionDaoProvider).getById(sessionId);
      if (session == null) {
        yield const [];
        return;
      }
      // A store record may not be the transcript itself (an agent whose store
      // is a database keeps a plain JSONL elsewhere on some installs), so the
      // agent's adapter resolves it once.
      final path = transcriptFileFor(session.filePath, session.cli);
      if (path == null) {
        yield const [];
        return;
      }
      final file = File(path);
      DateTime? lastModified;
      var firstRead = true;
      while (true) {
        DateTime? modified;
        try {
          // `stat()`, not the sync pair: on a `\\wsl.localhost\...` share the
          // pair measures 1.19 ms against 0.07 ms locally, on the UI isolate.
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
          yield await readCliTranscript(path, session.cli);
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

/// Repositories [sessionId] spans, primary first. Keyed by session, not by the
/// Explorer's selection: with two groups up they are different sessions.
final sessionRepositoriesProvider = Provider.autoDispose
    .family<List<Repository>, String>((ref, sessionId) {
      ref.watchSession(sessionId);
      return ref.read(sessionRepositoriesServiceProvider).forSession(sessionId);
    });

/// Live transcript for [id], refreshed whenever the engine appends an event.
/// Keyed by session, like [sessionRepositoriesProvider], because it is named.
final sessionTranscriptProvider = StreamProvider.autoDispose
    .family<List<SessionEvent>, String>((ref, id) async* {
      // Re-subscribe when *this* session is (re)started; another session
      // starting used to tear this stream down and rebuild it from the log.
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
