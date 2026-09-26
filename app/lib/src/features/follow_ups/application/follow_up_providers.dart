import 'package:riverpod/riverpod.dart';

import 'follow_up_service.dart';
import 'session_ending_observer.dart';

/// The only thing that raises and retires follow-ups.
final followUpServiceProvider = Provider<FollowUpService>(FollowUpService.new);

/// Watches sessions end. Its value is a **revision**: it stays put when a pass
/// changed nothing, so a watcher re-reads the table only when there is news.
final sessionEndingObserverProvider =
    NotifierProvider<SessionEndingObserver, int>(SessionEndingObserver.new);
