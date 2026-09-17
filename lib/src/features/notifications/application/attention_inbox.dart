import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../follow_ups/application/follow_up_inbox.dart';
import '../../follow_ups/application/follow_up_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_status_providers.dart';
import '../domain/inbox_item.dart';
import 'notification_providers.dart';

/// Holds the attention inbox and keeps it honest about what the user has seen.
/// "Looked at" is selected while the window has focus, as the policy reads it.
class AttentionInboxController extends Notifier<AttentionInbox> {
  @override
  AttentionInbox build() {
    ref.listen(selectedSessionIdProvider, (_, _) => _syncViewed());
    // Going to the tab is looking at it: clicking a tab sets no selection, so
    // without this an item retired "on viewing" missed the ordinary route.
    ref.listen(foregroundTerminalPaneIdsProvider, (_, _) => _syncViewed());
    ref.listen(selectedImportedSessionIdProvider, (_, _) => _syncViewed());
    ref.listen(windowFocusedProvider, (_, _) => _syncViewed());
    ref.listen(openFollowUpsProvider, (_, next) {
      state = state.syncFollowUps(next);
      // A follow-up for the session already on screen is not news either.
      _syncViewed();
    });
    // Seeded from the same provider, so sessions that ended while the app was
    // closed are listed at open rather than waiting for a change.
    return AttentionInbox.empty.syncFollowUps(ref.read(openFollowUpsProvider));
  }

  /// One poll's worth of observations.
  void apply(InboxUpdate update) {
    state = state.apply(update, ref.read(clockProvider).nowUtc());
    // A finished turn that arrives while its session is already on screen was
    // never news to this user; retire it in the same breath.
    _syncViewed();
  }

  /// Files one item nothing polls for. The same viewed rule applies.
  void raise(InboxItem item) {
    state = state.raise(item);
    _syncViewed();
  }

  void markAllSeen() => state = state.markAllSeen();

  /// Takes an item off the list for good. A follow-up is resolved in its table
  /// too, or the next sweep files it again.
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

  /// Reveals the next session that needs you. Goes through [open] so a chord
  /// marks an item viewed exactly as a click does.
  bool openNext() {
    final next = state.nextAfter(
      ref.read(selectedSessionIdProvider) ??
          ref.read(selectedImportedSessionIdProvider),
    );
    if (next == null) return false;
    open(next);
    return true;
  }

  void _syncViewed() {
    if (!ref.read(windowFocusedProvider)) return;
    // Nothing listed is nothing to retire, and asking what is on screen costs
    // a scan of the sessions table. `session_start_cost_test` counts it.
    if (state.items.isEmpty) return;
    final open = <String>{};
    final native = ref.read(selectedSessionIdProvider);
    if (native != null) open.add(native);
    final imported = ref.read(selectedImportedSessionIdProvider);
    if (imported != null) open.add(imported);
    // Targeted, not the whole placement map: `session_start_cost_test` asserts
    // no fifth provider re-reads every session row.
    final panes = ref.read(foregroundTerminalPaneIdsProvider);
    if (panes.isNotEmpty) {
      for (final row in ref.read(sessionDaoProvider).getByPaneIds(panes)) {
        open.add(row.id);
      }
    }
    if (open.isEmpty) return;
    state = state.viewed(open);
  }
}

final attentionInboxProvider =
    NotifierProvider<AttentionInboxController, AttentionInbox>(
      AttentionInboxController.new,
    );

/// The one attention count in the app — the status bar, the rail badge and the
/// tray all read this, so they cannot disagree.
final attentionCountProvider = Provider<int>(
  (ref) => ref.watch(attentionInboxProvider).unseen,
);
