import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/policy.dart';
import 'package:test/test.dart';

/// Settings → Notifications → Store changes, and the inbox kinds it files.
void main() {
  test('attention only unless chosen, and every choice round-trips', () {
    expect(
      const NotificationSettings().storeChanges,
      StoreChangeNotify.attention,
    );
    expect(
      NotificationSettings.fromJson(const {}).storeChanges,
      StoreChangeNotify.attention,
      reason: 'a record written before the choice existed',
    );
    for (final choice in StoreChangeNotify.values) {
      final settings = NotificationSettings(storeChanges: choice);
      expect(NotificationSettings.fromJson(settings.toJson()), settings);
    }
  });

  test('a store item goes when its app is looked at, and travels as a '
      'follow-up to an older app', () {
    for (final kind in [
      InboxItemKind.storeAttention,
      InboxItemKind.storeNews,
    ]) {
      expect(kind.retirement, InboxRetirement.viewing);
      expect(kind.wireName, InboxItemKind.followUp.name);
      expect(kind.reason, isNull);
    }
    expect(InboxItemKind.storeAttention.isQuiet, isFalse);
    expect(InboxItemKind.storeNews.isQuiet, isTrue);
  });
}
