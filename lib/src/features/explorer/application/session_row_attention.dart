import 'package:riverpod/riverpod.dart';

import '../../notifications/application/attention_inbox.dart';
import '../../notifications/domain/inbox_item.dart';

/// What a session row says about the unseen attention items for it.
enum SessionRowAttention {
  none,

  /// A turn finished that nobody has looked at (design-direction S2 unread).
  unread,

  /// The agent is waiting on the user.
  needsYou,
}

/// Unseen inbox items narrowed to one word per session id. Rows select their
/// own entry, so one notification wakes one row.
final sessionRowAttentionProvider = Provider<Map<String, SessionRowAttention>>((
  ref,
) {
  final byId = <String, SessionRowAttention>{};
  for (final item in ref.watch(attentionInboxProvider).pending) {
    final id = item.session.openId;
    final word = switch (item.kind) {
      InboxItemKind.needsApproval => SessionRowAttention.needsYou,
      InboxItemKind.finished => SessionRowAttention.unread,
      _ => null,
    };
    if (word == null || byId[id] == SessionRowAttention.needsYou) continue;
    byId[id] = word;
  }
  return Map.unmodifiable(byId);
});
