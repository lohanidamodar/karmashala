import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/watched.dart';

/// [changes] as the inbox files it: one item per app per read, opening the
/// app in the Stores tab, attention when any change wants a person.
InboxItem storeChangesInboxItem(StoreAppChanges changes) {
  final openId = storeInboxOpenId(changes.app.key);
  final stamp = changes.at.toUtc().millisecondsSinceEpoch;
  return InboxItem(
    session: WatchedSession(
      key: AgentSessionKey('stores', '${changes.app.key}@$stamp'),
      label: changes.title,
      openId: openId,
      imported: false,
    ),
    kind: changes.attention
        ? InboxItemKind.storeAttention
        : InboxItemKind.storeNews,
    at: changes.at,
    detail: changes.summary,
    id: '$openId@$stamp',
  );
}

/// Where the inbox items of apps [appKeys] point.
Set<String> storeInboxOpenIds(Iterable<String> appKeys) => {
  for (final key in appKeys) storeInboxOpenId(key),
};
