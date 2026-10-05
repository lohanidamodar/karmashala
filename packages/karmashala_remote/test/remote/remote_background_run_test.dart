import 'package:karmashala_remote/remote.dart';
import 'package:test/test.dart';

/// A session's background runs ride `session.activity` to the phone, and a
/// reading without any says nothing about them, so an older host reads as
/// none.
void main() {
  final observedAt = DateTime.utc(2026, 10, 5, 6, 5);

  test('runs cross the wire whole', () {
    final activity = RemoteSessionActivity(
      sessionId: 's1',
      observedAt: observedAt,
      background: [
        RemoteBackgroundRun(
          id: 'a1',
          agent: true,
          state: 'running',
          description: 'Strip idle detection',
          startedAt: DateTime.utc(2026, 10, 5, 6),
        ),
        RemoteBackgroundRun(
          id: 'brr24bsfs',
          agent: false,
          state: 'failed',
          startedAt: DateTime.utc(2026, 10, 5, 6, 1),
          endedAt: DateTime.utc(2026, 10, 5, 6, 3),
        ),
      ],
    );

    final back = RemoteSessionActivity.fromJson(activity.toJson());

    expect(back.background, activity.background);
    expect(back.background.first.isRunning, isTrue);
  });

  test('a reading with none carries no key, and reads back empty', () {
    final json = RemoteSessionActivity(
      sessionId: 's1',
      observedAt: observedAt,
    ).toJson();

    expect(json.containsKey('background'), isFalse);
    expect(RemoteSessionActivity.fromJson(json).background, isEmpty);
  });
}
