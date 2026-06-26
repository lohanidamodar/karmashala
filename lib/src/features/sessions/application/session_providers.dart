import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../data/session_dao.dart';
import '../data/session_event_dao.dart';

/// Repository-layer provider for session persistence.
final sessionDaoProvider = Provider<SessionDao>(
  (ref) => SessionDao(ref.watch(databaseProvider)),
);

/// Repository-layer provider for the append-only session event log.
final sessionEventDaoProvider = Provider<SessionEventDao>(
  (ref) => SessionEventDao(ref.watch(databaseProvider)),
);
