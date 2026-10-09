import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:store_console/store_console.dart';
import 'package:test/test.dart';

/// What changed in the stores, over the wire: the view's latest change sets
/// and schedule, the notice a read tells, and the two requests.
void main() {
  final at = DateTime.utc(2026, 10, 9, 8);
  const app = StoreApp(
    store: StoreKind.appStore,
    id: '1',
    bundleId: 'com.example.one',
    name: 'One',
  );
  final changes = StoreAppChanges(
    app: app,
    platform: 'iOS',
    at: at,
    changes: const [
      StoreChange(kind: StoreChangeKind.reviews, text: '1 new review (5★)'),
      StoreChange(
        kind: StoreChangeKind.release,
        text: '1.0 In review → Rejected',
        attention: true,
      ),
    ],
  );

  Map<String, Object?> overTheWire(Map<String, Object?> json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  test('a view carries its change sets and schedule', () {
    final view = StoresView(
      changes: [changes],
      schedule: StoreRefreshSchedule(
        every: const Duration(hours: 3),
        nextAt: at.add(const Duration(hours: 3)),
      ),
    );
    final back = StoresView.fromJson(overTheWire(view.toJson()));
    final held = back.changesOf(app.key)!;
    expect(held.changes, changes.changes);
    expect(held.attention, isTrue);
    expect(held.seen, isFalse);
    expect(
      held.sentence,
      'One (iOS): 1.0 In review → Rejected · 1 new review (5★)',
    );
    expect(back.schedule!.every, const Duration(hours: 3));
    expect(back.schedule!.nextAt, at.add(const Duration(hours: 3)));
  });

  test('a view from an older server has neither', () {
    final back = StoresView.fromJson(const {});
    expect(back.changes, isEmpty);
    expect(back.schedule, isNull);
  });

  test('a change of a kind a newer server knows reads as other', () {
    final back = StoreChange.fromJson(const {'kind': 'priceDrop', 'text': 'x'});
    expect(back.kind, StoreChangeKind.other);
  });

  test('a read\'s notice round-trips, and one app told keeps the changes', () {
    final batch = DataChanges(3, [
      StoreChangesNoticed([changes]),
    ]);
    final back = DataChanges.fromJson(overTheWire(batch.toJson()));
    final notice = back.changes.single as StoreChangesNoticed;
    expect(notice.changes.single.summary, changes.summary);

    final view = StoresView(
      changes: [changes],
    ).withApp(const StoreAppChanged(app: app, read: StoreAppRead.queued()));
    expect(view.changesOf(app.key), isNotNull);
  });

  test('stores.seen and stores.schedule.set round-trip', () {
    DataRequest<Object?> roundTrip(DataRequest<Object?> request) {
      final read = DataEnvelope.readRequest(
        overTheWire(DataEnvelope.request(7, request)),
      );
      expect(read.refusal, isNull);
      return read.request!;
    }

    expect((roundTrip(StoresSeen([app.key])) as StoresSeen).appKeys, [app.key]);
    expect(
      (roundTrip(const StoresScheduleSet(Duration(hours: 6)))
              as StoresScheduleSet)
          .every,
      const Duration(hours: 6),
    );
  });

  test('an inbox address names its app, and only a store one does', () {
    expect(storeAppKeyOfInboxId(storeInboxOpenId(app.key)), app.key);
    expect(storeAppKeyOfInboxId('a-session-id'), isNull);
  });
}
