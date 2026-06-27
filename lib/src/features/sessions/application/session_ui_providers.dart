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

/// Bumped to force the session list to re-read after a create/stop.
class SessionsRevisionController extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final sessionsRevisionProvider =
    NotifierProvider<SessionsRevisionController, int>(
      SessionsRevisionController.new,
    );

/// Sessions belonging to the currently selected repository.
final sessionsForSelectedRepositoryProvider =
    Provider.autoDispose<List<Session>>((ref) {
      ref.watch(sessionsRevisionProvider);
      final repoId = ref.watch(selectedRepositoryIdProvider);
      if (repoId == null) return const [];
      return ref.read(sessionDaoProvider).getByRepository(repoId);
    });

/// Imported CLI sessions belonging to the selected repository.
final importedSessionsForSelectedRepositoryProvider =
    Provider.autoDispose<List<ImportedSession>>((ref) {
      ref.watch(sessionsRevisionProvider);
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
          modified = file.existsSync() ? file.lastModifiedSync() : null;
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

/// Repositories the selected session spans (primary first). Refreshes on a
/// revision bump (after attach/detach).
final selectedSessionRepositoriesProvider =
    Provider.autoDispose<List<Repository>>((ref) {
      ref.watch(sessionsRevisionProvider);
      final id = ref.watch(selectedSessionIdProvider);
      if (id == null) return const [];
      return ref.read(sessionRepositoriesServiceProvider).forSession(id);
    });

/// Live transcript for the selected session: the persisted event history,
/// refreshed whenever the engine appends a new event to an active session.
final sessionTranscriptProvider =
    StreamProvider.autoDispose<List<SessionEvent>>((ref) async* {
      // Re-subscribe when a session is (re)started so a freshly relaunched
      // agent's live stream is picked up.
      ref.watch(sessionsRevisionProvider);
      final id = ref.watch(selectedSessionIdProvider);
      if (id == null) {
        yield const [];
        return;
      }
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
