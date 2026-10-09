import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:store_console/store_console.dart';

/// Fake store history for the Stores tests: test values only, never read
/// from a store.

/// The phone widths and a desktop, and the text scales, every new Stores
/// surface is drawn at.
const List<Size> kStoreTestSizes = [
  Size(360, 800),
  Size(412, 900),
  Size(1440, 900),
];
const List<double> kStoreTestTextScales = [1.0, 1.6];

/// Draws at [size] and [textScale] for the rest of the test.
void setStoreTestSurface(WidgetTester tester, Size size, double textScale) {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

StoreReleaseStep storeStep(
  String version,
  ReleaseState state,
  String words,
  DateTime at, {
  String track = 'App Store',
  String? build,
  double? rollout,
  bool firstRead = false,
  String? rawState,
}) => StoreReleaseStep(
  track: track,
  version: version,
  build: build,
  state: state,
  rawState: rawState ?? state.name,
  words: words,
  rollout: rollout,
  at: at,
  firstRead: firstRead,
);

/// Three App Store releases: 2.4.0 rejected after 1d 4h, 2.3.0 approved
/// after 1d 4h and live, 2.2.0 first read already live.
List<StoreReleaseStep> appleSteps() => [
  storeStep(
    '2.2.0',
    ReleaseState.live,
    'Ready for sale',
    DateTime.utc(2026, 9, 1, 8),
    firstRead: true,
  ),
  storeStep(
    '2.3.0',
    ReleaseState.waitingForReview,
    'Waiting for review',
    DateTime.utc(2026, 9, 20, 8),
  ),
  storeStep(
    '2.3.0',
    ReleaseState.inReview,
    'In review',
    DateTime.utc(2026, 9, 21, 6),
  ),
  storeStep(
    '2.3.0',
    ReleaseState.pendingRelease,
    'Approved',
    DateTime.utc(2026, 9, 21, 12),
  ),
  storeStep(
    '2.3.0',
    ReleaseState.live,
    'Ready for sale',
    DateTime.utc(2026, 9, 22, 9),
  ),
  storeStep(
    '2.4.0',
    ReleaseState.waitingForReview,
    'Waiting for review',
    DateTime.utc(2026, 10, 1, 8),
  ),
  storeStep(
    '2.4.0',
    ReleaseState.inReview,
    'In review',
    DateTime.utc(2026, 10, 2, 9),
  ),
  storeStep(
    '2.4.0',
    ReleaseState.rejected,
    'Metadata rejected',
    DateTime.utc(2026, 10, 2, 12),
    rawState: 'METADATA_REJECTED',
  ),
];

/// One Play release through review and a staged rollout to everyone.
List<StoreReleaseStep> playSteps() => [
  storeStep(
    '2.0.0',
    ReleaseState.inReview,
    'In review',
    DateTime.utc(2026, 10, 1, 8),
    track: 'production',
    build: '20',
  ),
  storeStep(
    '2.0.0',
    ReleaseState.rollingOut,
    'Rolling out 10%',
    DateTime.utc(2026, 10, 2, 10),
    track: 'production',
    build: '20',
    rollout: 0.1,
  ),
  storeStep(
    '2.0.0',
    ReleaseState.rollingOut,
    'Rolling out 50%',
    DateTime.utc(2026, 10, 4, 10),
    track: 'production',
    build: '20',
    rollout: 0.5,
  ),
  storeStep(
    '2.0.0',
    ReleaseState.live,
    'Live',
    DateTime.utc(2026, 10, 6, 10),
    track: 'production',
    build: '20',
  ),
];

/// [days] days ending on [end], every third day unread, crash rates only on
/// even days.
List<StoreDay> storeDays(DateTime end, {int days = 20}) => [
  for (var i = days - 1; i >= 0; i--)
    if (i % 3 != 1)
      StoreDay(
        day: DateTime.utc(end.year, end.month, end.day - i),
        rating: 4.0 + (i % 5) / 10,
        ratingCount: 1000 + i,
        reviews: i % 4,
        crashRate: i.isEven ? 0.002 + i / 10000 : null,
        installs: i < 3 ? null : 40 + i,
      ),
];
