import 'dart:async';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_providers.dart';
import '../../follow_ups/application/follow_up_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_status_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import 'notification_providers.dart';

final _log = AppLogger.named('notifications.inbox');

/// The attention inbox **as the server keeps it** (slice 5c): the server
/// decides what needs a person and files it, follow-ups included; this is
/// the copy it tells this app, and the verbs a person uses on it, each asked
/// of the server. The one thing this window says on its own is what it is
/// looking at (`inbox.seen`), since only it knows its focus and selection.
class AttentionInboxController extends Notifier<AttentionInbox> {
  /// What this window last said it was looking at, so the same set is not
  /// said twice.
  Set<String>? _lastSeen;

  @override
  AttentionInbox build() {
    // Follow-ups are raised from recorded endings by the sweep this keeps
    // running; the server files them in the inbox.
    ref.watch(sessionEndingObserverProvider);
    final client = ref.watch(dataClientProvider);
    _lastSeen = null;
    final changes = client.attentionChanges.listen((change) {
      switch (change) {
        case InboxChanged(:final snapshot):
          // What this window looks at is the server's to mark seen too; a
          // batch that crossed the saying of it is marked the same here.
          state = snapshot.inbox.viewed(_lastSeen ?? const {});
        case InboxOpenWanted(:final openId, :final imported):
          focusWatchedSession(
            ref.container,
            openId: openId,
            imported: imported,
          );
        default:
          break;
      }
    });
    final connection = client.connectionChanges.listen((_) {
      // A new link knows nothing of what this window looks at.
      _lastSeen = null;
      _syncViewed();
    });
    ref.onDispose(() {
      unawaited(changes.cancel());
      unawaited(connection.cancel());
    });
    ref.listen(selectedSessionIdProvider, (_, _) => _syncViewed());
    // Going to the tab is looking at it: clicking a tab sets no selection.
    ref.listen(foregroundTerminalPaneIdsProvider, (_, _) => _syncViewed());
    ref.listen(selectedImportedSessionIdProvider, (_, _) => _syncViewed());
    ref.listen(windowFocusedProvider, (_, _) => _syncViewed());
    // What this window already shows is said at once: nothing about it is
    // news, here or at the server.
    final looking = _lookingAt();
    _lastSeen = looking;
    // A new link looks at nothing until told: an empty set is not said.
    if (looking.isNotEmpty) _send(InboxSeen(looking.toList()..sort()));
    return client.attention.inbox.viewed(looking);
  }

  void _send(DataRequest<Object?> request) {
    unawaited(
      ref
          .read(dataClientProvider)
          .send(request)
          .then<void>(
            (_) {},
            onError: (Object error) =>
                _log.warning('${request.kind} was not answered: $error'),
          ),
    );
  }

  /// Files one item the server does not watch for itself (a usage limit a
  /// client saw). The same viewed rule applies there.
  void raise(InboxItem item) {
    state = state.raise(item);
    _send(InboxRaise(item));
  }

  void markAllSeen() {
    state = state.markAllSeen();
    _send(const InboxMarkAllSeen());
  }

  /// Takes an item off the list for good; a follow-up is resolved in its
  /// table by the server.
  void dismiss(String id) {
    state = state.dismiss(id);
    _send(InboxDismiss(id));
  }

  /// Opens an item: seen at the server, which tells every window — this one
  /// too — to show its session.
  void open(InboxItem item) {
    state = state.viewed({item.session.openId});
    _send(InboxOpen(item.id));
  }

  /// Opens the next session that needs you — one waiting on an answer, not
  /// one that merely finished — through [open].
  bool openNext() {
    final next = state.nextAfter(
      ref.read(selectedSessionIdProvider) ??
          ref.read(selectedImportedSessionIdProvider),
      where: (item) => item.kind == InboxItemKind.needsApproval,
    );
    if (next == null) return false;
    open(next);
    return true;
  }

  /// What this window is looking at: the selected sessions and the
  /// foreground panes' rows while it has focus, nothing while not.
  Set<String> _lookingAt() {
    final looking = <String>{};
    if (!ref.read(windowFocusedProvider)) return looking;
    final native = ref.read(selectedSessionIdProvider);
    if (native != null) looking.add(native);
    final imported = ref.read(selectedImportedSessionIdProvider);
    if (imported != null) looking.add(imported);
    final panes = ref.read(foregroundTerminalPaneIdsProvider);
    if (panes.isNotEmpty) {
      for (final row in ref.read(sessionsDataProvider).getByPaneIds(panes)) {
        looking.add(row.id);
      }
    }
    return looking;
  }

  /// Tells the server what this window is looking at: the selected sessions
  /// and the foreground panes' rows while it has focus, nothing while not.
  void _syncViewed() {
    final looking = _lookingAt();
    final last = _lastSeen;
    if (last != null &&
        last.length == looking.length &&
        last.containsAll(looking)) {
      return;
    }
    _lastSeen = looking;
    if (looking.isNotEmpty) state = state.viewed(looking);
    _send(InboxSeen(looking.toList()..sort()));
  }
}

final attentionInboxProvider =
    NotifierProvider<AttentionInboxController, AttentionInbox>(
      AttentionInboxController.new,
    );

/// The one attention count in the app — the activity strip's badges and the
/// tray all read this, so they cannot disagree.
final attentionCountProvider = Provider<int>(
  (ref) => ref.watch(attentionInboxProvider).unseen,
);
