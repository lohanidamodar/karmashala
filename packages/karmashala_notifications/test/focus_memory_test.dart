import 'package:karmashala_notifications/policy.dart';
import 'package:test/test.dart';

void main() {
  test('Focus is off by default', () {
    expect(const NotificationSettings().focus, isNull);
  });

  test('Focus and what it replaced round-trip', () {
    const settings = NotificationSettings(
      level: NotifyLevel.whenNeeded,
      focus: FocusMemory(level: NotifyLevel.nothing, hideWorking: false),
    );
    final back = NotificationSettings.fromJson(settings.toJson());
    expect(back, settings);
    expect(back.focus!.level, NotifyLevel.nothing);
    expect(back.focus!.hideWorking, isFalse);
  });

  test('a malformed focus record reads as Focus off', () {
    expect(NotificationSettings.fromJson(const {'focus': 'yes'}).focus, isNull);
    expect(
      NotificationSettings.fromJson(const {
        'focus': {'level': 'loud', 'hideWorking': true},
      }).focus,
      isNull,
    );
  });

  test('a record from before Focus reads as Focus off', () {
    expect(
      NotificationSettings.fromJson(const {'level': 'everything'}).focus,
      isNull,
    );
  });

  test('copyWith can end Focus', () {
    const on = NotificationSettings(
      focus: FocusMemory(level: NotifyLevel.everything, hideWorking: true),
    );
    expect(on.copyWith(endFocus: true).focus, isNull);
    expect(on.copyWith(level: NotifyLevel.nothing).focus, on.focus);
  });
}
