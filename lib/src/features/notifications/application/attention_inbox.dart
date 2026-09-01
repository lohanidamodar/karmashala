import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../follow_ups/application/follow_up_inbox.dart';
import '../../follow_ups/application/follow_up_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../domain/inbox_item.dart';
import 'notification_providers.dart';

/// Holds the attention inbox and keeps it honest about what the user has seen.
///
/// Three inputs, and none of them is a timer of its own:
///
/// * the **watcher**, through `AgentStatusWatcher.onInbox`, wired in
///   `notification_providers.dart`;
/// * the **selection**, so an item retires when its source is looked at;
/// * the **follow-up store**, through `openFollowUpsProvider` — what sessions
///   left behind when they ended. Listened to rather than watched: a change in
///   the store must fold into the list, not rebuild the notifier and throw away
///   everything the poll has put there.
///
/// "Looked at" means *selected while the window has focus* — the same reading
/// `AgentNotificationPolicy` already uses for "the session on screen", because
/// a session selected behind a browser is not being looked at and clearing its
/// inbox entry there would lose exactly the thing the inbox exists for.
class AttentionInboxController extends Notifier<AttentionInbox> {
  @override
  AttentionInbox build() {
    ref.listen(selectedSessionIdProvider, (_, _) => _syncViewed());
    ref.listen(selectedImportedSessionIdProvider, (_, _) => _syncViewed());
    ref.listen(windowFocusedProvider, (_, _) => _syncViewed());
    ref.listen(openFollowUpsProvider, (_, next) {
      state = state.syncFollowUps(next);
      // A follow-up for the session already on screen is not news either.
      _syncViewed();
    });
    // Seeded from the same provider the listener above watches, so a workspace
    // whose sessions ended while the app was closed opens with them listed
    // rather than waiting for something to change first.
    return AttentionInbox.empty.syncFollowUps(ref.read(openFollowUpsProvider));
  }

  /// One poll's worth of observations.
  void apply(InboxUpdate update) {
    state = state.apply(update, ref.read(clockProvider).nowUtc());
    // A finished turn that arrives while its session is already on screen was
    // never news to this user; retire it in the same breath.
    _syncViewed();
  }

  void markAllSeen() => state = state.markAllSeen();

  /// Takes an item off the list for good.
  ///
  /// A follow-up is resolved in its **table** as well, and it has to be: the
  /// session row that raised it goes on saying `failed` forever, so an item
  /// removed only from this list would be back on the next sweep.
  void dismiss(String id) {
    if (followUpRowIdIn(id) case final rowId?) {
      ref.read(followUpServiceProvider).dismissRow(rowId);
    }
    state = state.dismiss(id);
  }

  /// Opens an item's source and, by doing so, marks it seen.
  void open(InboxItem item) {
    focusWatchedSession(
      ref.container,
      openId: item.session.openId,
      imported: item.session.imported,
    );
    state = state.viewed({item.session.openId});
  }

  void _syncViewed() {
    if (!ref.read(windowFocusedProvider)) return;
    final open = <String>{};
    final native = ref.read(selectedSessionIdProvider);
    if (native != null) open.add(native);
    final imported = ref.read(selectedImportedSessionIdProvider);
    if (imported != null) open.add(imported);
    if (open.isEmpty) return;
    state = state.viewed(open);
  }
}

final attentionInboxProvider =
    NotifierProvider<AttentionInboxController, AttentionInbox>(
      AttentionInboxController.new,
    );

/// The one attention count in the app.
///
/// The status bar, the side panel's rail badge and the tray badge all read
/// this, so they cannot disagree. Loop 42's tray counted the *current*
/// attention set instead, which is a different number the moment a finished
/// turn is waiting or a watched session goes quiet.
final attentionCountProvider = Provider<int>(
  (ref) => ref.watch(attentionInboxProvider).unseen,
);
