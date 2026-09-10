import 'package:riverpod/riverpod.dart';

import '../domain/session_last_active.dart';
import 'session_status_providers.dart';

/// The newest reading the app holds about session [openId] — a native session
/// row id or an imported conversation's — with [storeModifiedAt] for a row
/// whose CLI store file is the only thing that dates it.
typedef SessionLastActiveLookup =
    SessionLastActive Function(String openId, {DateTime? storeModifiedAt});

/// **The one reading every session list orders by.**
///
/// A function behind a provider rather than a `family`, for
/// [sessionStatusLookupProvider]'s reason: the lists ask it once per session on
/// every rebuild, and a family would cache the first answer to a question whose
/// whole value is being current.
///
/// It costs nothing and starts nothing. The status registry is already cycling
/// for the badges — hooks land in it as they arrive, transcripts and pane
/// screens on its own budgeted rotation — so this is a map lookup, not a
/// filesystem sweep. That is what makes it affordable in Quick Open, which
/// rebuilds its whole list on every keystroke.
///
/// A session the registry has never seen reads as [SessionLastActive.unknown]
/// and sorts last. That is honest: an imported row nobody has opened and a
/// session in somebody else's terminal are both sessions we hold no evidence
/// about, and inventing one would put them at the top of a list they have no
/// claim to.
final sessionLastActiveProvider = Provider<SessionLastActiveLookup>((ref) {
  final statusOf = ref.read(sessionStatusLookupProvider);
  return (openId, {DateTime? storeModifiedAt}) => newestLastActive(
    agentEvidenceAt: agentEvidenceAt(statusOf(openId)),
    storeModifiedAt: storeModifiedAt,
  );
});
