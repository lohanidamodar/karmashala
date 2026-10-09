import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:store_console/store_console.dart';
import 'package:test/test.dart';

/// The stores' history over the wire: compact day rows with their unknowns,
/// release steps, and the request that asks for them. Test values only.
void main() {
  const app = StoreApp(
    store: StoreKind.googlePlay,
    id: 'com.example.one',
    bundleId: 'com.example.one',
    name: 'One',
  );

  Map<String, Object?> overTheWire(Map<String, Object?> json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  test('a history view round-trips, unknowns kept unknown', () {
    final view = StoreHistoryView(
      keptDays: 365,
      apps: [
        StoreAppHistory(
          app: app,
          days: [
            StoreDay(day: DateTime.utc(2026, 10, 8), rating: 4.4, reviews: 0),
            StoreDay(
              day: DateTime.utc(2026, 10, 9),
              crashRate: 0.012,
              installs: 30,
            ),
          ],
          steps: [
            StoreReleaseStep(
              track: 'production',
              version: '2.0',
              build: '7',
              state: ReleaseState.rollingOut,
              rawState: 'inProgress',
              words: 'Rolling out 20%',
              rollout: 0.2,
              at: DateTime.utc(2026, 10, 9, 8),
              firstRead: true,
            ),
          ],
        ),
      ],
    );
    final again = StoreHistoryView.fromJson(overTheWire(view.toJson()));
    expect(again.keptDays, 365);
    final held = again.of(app.key)!;
    expect(held.days.first.day, DateTime.utc(2026, 10, 8));
    expect(held.days.first.rating, 4.4);
    expect(held.days.first.reviews, 0);
    expect(held.days.first.crashRate, isNull);
    expect(held.days.last.installs, 30);
    expect(held.days.last.rating, isNull);
    final step = held.steps.single;
    expect(step.words, 'Rolling out 20%');
    expect(step.rollout, 0.2);
    expect(step.firstRead, isTrue);
    expect(step.state, ReleaseState.rollingOut);
  });

  test('a newer day fills in a day without blanking what it knew', () {
    final day = StoreDay(day: DateTime.utc(2026, 10, 9), rating: 4.1);
    final merged = day.mergedWith(
      StoreDay(day: DateTime.utc(2026, 10, 9), anrRate: 0.001),
    );
    expect(merged.rating, 4.1);
    expect(merged.anrRate, 0.001);
  });

  test('stores.history round-trips', () {
    final read = DataEnvelope.readRequest(
      overTheWire(
        DataEnvelope.request(3, StoresHistoryGet(appKeys: [app.key], days: 90)),
      ),
    );
    expect(read.refusal, isNull);
    final request = read.request! as StoresHistoryGet;
    expect(request.appKeys, [app.key]);
    expect(request.days, 90);
  });
}
