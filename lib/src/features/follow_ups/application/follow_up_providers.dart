import 'package:riverpod/riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../data/follow_up_dao.dart';
import 'follow_up_service.dart';
import 'session_ending_observer.dart';

/// Repository-layer provider for what sessions left behind.
final followUpDaoProvider = Provider<FollowUpDao>(
  (ref) => FollowUpDao(ref.watch(databaseProvider)),
);

/// The only thing that raises and retires follow-ups.
final followUpServiceProvider = Provider<FollowUpService>(FollowUpService.new);

/// Watches sessions end. Its value is a **revision**: it stays put when a pass
/// changed nothing, so a watcher re-reads the table only when there is news.
final sessionEndingObserverProvider =
    NotifierProvider<SessionEndingObserver, int>(SessionEndingObserver.new);
