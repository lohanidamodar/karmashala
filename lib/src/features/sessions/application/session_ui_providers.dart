import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../git/application/changes_providers.dart';
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

/// The session whose transcript is shown, or `null`.
class SelectedSessionController extends Notifier<String?> {
  @override
  String? build() => null;
  void select(String? id) => state = id;
}

final selectedSessionIdProvider =
    NotifierProvider<SelectedSessionController, String?>(
      SelectedSessionController.new,
    );

/// Live transcript for the selected session: the persisted event history,
/// refreshed whenever the engine appends a new event to an active session.
final sessionTranscriptProvider =
    StreamProvider.autoDispose<List<SessionEvent>>((ref) async* {
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
