import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/data_providers.dart';
import 'session_notice.dart';

/// **What the server has to say of a session** (`SessionNoticed`) — an image
/// a queued message gave the agent as a path, say — posted on that session's
/// own bar, however the message went. Must be watched (Riverpod 3).
class ServerSessionNotices extends Notifier<int> {
  @override
  int build() {
    final notices = ref.watch(dataClientProvider).sessionNotices.listen((
      change,
    ) {
      ref
          .read(sessionNoticesProvider.notifier)
          .post(change.sessionId, SessionNotice(message: change.message));
    });
    ref.onDispose(notices.cancel);
    return 0;
  }
}

final serverSessionNoticesProvider =
    NotifierProvider<ServerSessionNotices, int>(ServerSessionNotices.new);
