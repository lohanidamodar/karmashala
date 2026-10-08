import 'package:riverpod/riverpod.dart';

import '../data/sessions_client.dart';

/// **Detaches a session from its parent**, at the server: it becomes a
/// top-level session and nothing goes between the two any more. A refusal is
/// thrown as a [StateError] in the server's own words.
final sessionDetachProvider = Provider<Future<void> Function(String sessionId)>(
  (ref) => ref.watch(sessionsClientProvider).detach,
);
