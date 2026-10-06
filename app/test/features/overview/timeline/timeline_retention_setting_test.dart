import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';

/// Settings › Server › Storage › Keep the timeline for: the key the server's
/// sweep reads (`kActivityLogKeepDaysSetting`).
void main() {
  test('the timeline is kept forever unless a number of days is set', () {
    expect(const Settings().activityLogKeepDays, 0);
    expect(Settings.fromJson(const {}).activityLogKeepDays, 0);
    expect(
      Settings.fromJson(const {'activityLogKeepDays': -3}).activityLogKeepDays,
      0,
    );
    expect(
      Settings.fromJson(const {'activityLogKeepDays': 'x'}).activityLogKeepDays,
      0,
    );
  });

  test('a limit round-trips under the key the server reads', () {
    final settings = const Settings().copyWith(activityLogKeepDays: 90);
    final json = settings.toJson();
    expect(json['activityLogKeepDays'], 90);
    expect(Settings.fromJson(json).activityLogKeepDays, 90);
    expect(Settings.fromJson(json), settings);
  });
}
