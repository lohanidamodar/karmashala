import 'package:riverpod/riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../../repositories/application/repository_providers.dart';
import 'session_repositories_service.dart';
import '../data/session_dao.dart';
import '../data/decision_record_dao.dart';
import '../data/session_event_dao.dart';
import '../data/session_recap_dao.dart';
import '../data/session_repository_dao.dart';

/// Repository-layer provider for session persistence.
final sessionDaoProvider = Provider<SessionDao>(
  (ref) => SessionDao(ref.watch(databaseProvider)),
);

/// Repository-layer provider for the append-only session event log.
final sessionEventDaoProvider = Provider<SessionEventDao>(
  (ref) => SessionEventDao(ref.watch(databaseProvider)),
);

/// Repository-layer provider for the append-only decision record.
final decisionRecordDaoProvider = Provider<DecisionRecordDao>(
  (ref) => DecisionRecordDao(ref.watch(databaseProvider)),
);

/// Repository-layer provider for the recap a session was asked for.
final sessionRecapDaoProvider = Provider<SessionRecapDao>(
  (ref) => SessionRecapDao(ref.watch(databaseProvider)),
);

/// Repository-layer provider for the session↔repository link table.
final sessionRepositoryDaoProvider = Provider<SessionRepositoryDao>(
  (ref) => SessionRepositoryDao(ref.watch(databaseProvider)),
);

/// Manages the repositories a session spans (within one project).
final sessionRepositoriesServiceProvider = Provider<SessionRepositoriesService>(
  (ref) => SessionRepositoriesService(
    sessionDao: ref.watch(sessionDaoProvider),
    repositoryDao: ref.watch(repositoryDaoProvider),
    linkDao: ref.watch(sessionRepositoryDaoProvider),
  ),
);
