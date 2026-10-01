import 'package:store_console/store_console.dart';
import 'package:store_console_apple/src/apple_states.dart';
import 'package:test/test.dart';

void main() {
  test('every version state Apple documents maps to its reduced state', () {
    const expected = {
      'READY_FOR_SALE': ReleaseState.live,
      'READY_FOR_DISTRIBUTION': ReleaseState.live,
      'WAITING_FOR_REVIEW': ReleaseState.waitingForReview,
      'IN_REVIEW': ReleaseState.inReview,
      'PENDING_DEVELOPER_RELEASE': ReleaseState.pendingRelease,
      'PENDING_APPLE_RELEASE': ReleaseState.pendingRelease,
      'PREPARE_FOR_SUBMISSION': ReleaseState.draft,
      'DEVELOPER_REJECTED': ReleaseState.draft,
      'REJECTED': ReleaseState.rejected,
      'METADATA_REJECTED': ReleaseState.rejected,
      'INVALID_BINARY': ReleaseState.rejected,
      'PROCESSING_FOR_APP_STORE': ReleaseState.processing,
      'PROCESSING_FOR_DISTRIBUTION': ReleaseState.processing,
      'REPLACED_WITH_NEW_VERSION': ReleaseState.superseded,
      'REMOVED_FROM_SALE': ReleaseState.removed,
      'DEVELOPER_REMOVED_FROM_SALE': ReleaseState.removed,
      'WAITING_FOR_EXPORT_COMPLIANCE': ReleaseState.unknown,
      'SOMETHING_NEW': ReleaseState.unknown,
      '': ReleaseState.unknown,
    };
    for (final MapEntry(key: raw, value: state) in expected.entries) {
      expect(versionState(raw), state, reason: raw);
    }
  });

  test('a phased release changes only a live version', () {
    expect(
      versionState('READY_FOR_DISTRIBUTION', phasedState: 'ACTIVE'),
      ReleaseState.rollingOut,
    );
    expect(
      versionState('READY_FOR_SALE', phasedState: 'PAUSED'),
      ReleaseState.halted,
    );
    expect(
      versionState('READY_FOR_SALE', phasedState: 'COMPLETE'),
      ReleaseState.live,
    );
    expect(
      versionState('IN_REVIEW', phasedState: 'INACTIVE'),
      ReleaseState.inReview,
    );
  });

  test('the phased share follows the seven-day table', () {
    expect(
      [for (var day = 1; day <= 7; day++) phasedFraction(day)],
      [0.01, 0.02, 0.05, 0.10, 0.20, 0.50, 1.0],
    );
    expect(phasedFraction(0), isNull);
    expect(phasedFraction(null), isNull);
    expect(phasedFraction(9), 1.0);
  });

  test('only the older field can say a version was removed', () {
    expect(
      rawVersionState('READY_FOR_DISTRIBUTION', 'REMOVED_FROM_SALE'),
      'REMOVED_FROM_SALE',
    );
    expect(
      rawVersionState('READY_FOR_DISTRIBUTION', 'READY_FOR_SALE'),
      'READY_FOR_DISTRIBUTION',
    );
    expect(rawVersionState(null, 'IN_REVIEW'), 'IN_REVIEW');
    expect(rawVersionState(null, null), '');
  });

  test('build states', () {
    expect(buildState('PROCESSING', expired: false), ReleaseState.processing);
    expect(buildState('VALID', expired: false), ReleaseState.testing);
    expect(buildState('VALID', expired: true), ReleaseState.superseded);
    expect(buildState('FAILED', expired: false), ReleaseState.rejected);
    expect(buildState('INVALID', expired: false), ReleaseState.rejected);
    expect(buildState(null, expired: false), ReleaseState.unknown);
  });

  test('the track names the platform when it is not iOS', () {
    expect(appStoreTrack('IOS'), 'App Store');
    expect(appStoreTrack('MAC_OS'), 'App Store (macOS)');
    expect(appStoreTrack('TV_OS'), 'App Store (tvOS)');
  });

  test('live leads, then what is in flight or stuck, TestFlight last', () {
    StoreRelease release(String track, ReleaseState state, int day) =>
        StoreRelease(
          track: track,
          version: '$day',
          state: state,
          rawState: '',
          date: DateTime.utc(2026, 9, day),
        );
    final ordered = orderReleases([
      release(testFlightTrack, ReleaseState.testing, 29),
      release('App Store', ReleaseState.superseded, 1),
      release('App Store', ReleaseState.rejected, 20),
      release('App Store', ReleaseState.inReview, 25),
      release('App Store', ReleaseState.live, 10),
    ]);
    expect(
      [for (final release in ordered) release.state],
      [
        ReleaseState.live,
        ReleaseState.inReview,
        ReleaseState.rejected,
        ReleaseState.superseded,
        ReleaseState.testing,
      ],
    );
  });
}
