import 'package:riverpod/riverpod.dart';

import '../domain/session_last_active.dart';
import 'session_status_providers.dart';

/// The newest reading the app holds about session [openId] — a native session
/// row id or an imported conversation's — with [storeModifiedAt] for a row
/// whose CLI store file is the only thing that dates it.
typedef SessionLastActiveLookup =
    SessionLastActive Function(String openId, {DateTime? storeModifiedAt});

/// **The one reading every session list orders by.** A function behind a
/// provider rather than a `family`, for [sessionStatusLookupProvider]'s reason:
/// the lists ask it once per session on every rebuild, and a family would cache
/// the first answer to a question whose whole value is being current.
///
/// It costs nothing and starts nothing — the status registry is already cycling
/// for the badges, so this is a map lookup rather than a filesystem sweep,
/// which is what makes it affordable in Quick Open. A session the registry has
/// never seen reads as [SessionLastActive.unknown] and sorts last, which is
/// honest.
final sessionLastActiveProvider = Provider<SessionLastActiveLookup>((ref) {
  final statusOf = ref.read(sessionStatusLookupProvider);
  return (openId, {DateTime? storeModifiedAt}) => newestLastActive(
    agentEvidenceAt: agentEvidenceAt(statusOf(openId)),
    storeModifiedAt: storeModifiedAt,
  );
});
