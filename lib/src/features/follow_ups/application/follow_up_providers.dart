import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../data/follow_up_dao.dart';
import 'follow_up_service.dart';
import 'session_ending_observer.dart';

/// Repository-layer provider for what sessions left behind.
final followUpDaoProvider = Provider<FollowUpDao>(
  (ref) => FollowUpDao(ref.watch(databaseProvider)),
);

/// The only thing that raises and retires follow-ups.
final followUpServiceProvider = Provider<FollowUpService>(
  FollowUpService.new,
);

/// Watches sessions end. Nothing reads its value; it is mounted for its effect,
/// the way `sessionCheckpointRecorderProvider` is.
final sessionEndingObserverProvider =
    NotifierProvider<SessionEndingObserver, int>(SessionEndingObserver.new);
