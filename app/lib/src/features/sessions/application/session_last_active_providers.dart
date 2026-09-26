import 'package:riverpod/riverpod.dart';

import 'package:karmashala_session/resume.dart';
import 'session_status_providers.dart';

/// The newest reading the app holds about session [openId], with
/// [storeModifiedAt] for a row only its CLI store file can date.
typedef SessionLastActiveLookup =
    SessionLastActive Function(String openId, {DateTime? storeModifiedAt});

/// **The one reading every session list orders by** — a map lookup, not a
/// sweep, which is what makes it affordable in Quick Open. Unknown sorts last.
final sessionLastActiveProvider = Provider<SessionLastActiveLookup>((ref) {
  final statusOf = ref.read(sessionStatusLookupProvider);
  return (openId, {DateTime? storeModifiedAt}) => newestLastActive(
    agentEvidenceAt: agentEvidenceAt(statusOf(openId)),
    storeModifiedAt: storeModifiedAt,
  );
});
