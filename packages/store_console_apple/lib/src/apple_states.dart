import 'package:store_console/store_console.dart';

const testFlightTrack = 'TestFlight';

/// Apple's published share of users for each day of a phased release.
const _phasedShare = [0.01, 0.02, 0.05, 0.10, 0.20, 0.50, 1.0];

const _removedStates = {'REMOVED_FROM_SALE', 'DEVELOPER_REMOVED_FROM_SALE'};

const _versionStates = {
  'READY_FOR_SALE': ReleaseState.live,
  'READY_FOR_DISTRIBUTION': ReleaseState.live,
  'PREORDER_READY_FOR_SALE': ReleaseState.live,
  'WAITING_FOR_REVIEW': ReleaseState.waitingForReview,
  'IN_REVIEW': ReleaseState.inReview,
  'PENDING_DEVELOPER_RELEASE': ReleaseState.pendingRelease,
  'PENDING_APPLE_RELEASE': ReleaseState.pendingRelease,
  'PREPARE_FOR_SUBMISSION': ReleaseState.draft,
  'DEVELOPER_REJECTED': ReleaseState.draft,
  'READY_FOR_REVIEW': ReleaseState.draft,
  'REJECTED': ReleaseState.rejected,
  'METADATA_REJECTED': ReleaseState.rejected,
  'INVALID_BINARY': ReleaseState.rejected,
  'PROCESSING_FOR_APP_STORE': ReleaseState.processing,
  'PROCESSING_FOR_DISTRIBUTION': ReleaseState.processing,
  'REPLACED_WITH_NEW_VERSION': ReleaseState.superseded,
  'REMOVED_FROM_SALE': ReleaseState.removed,
  'DEVELOPER_REMOVED_FROM_SALE': ReleaseState.removed,
};

/// The word to read a version's state from, given `appVersionState` and the
/// deprecated `appStoreState`.
String rawVersionState(String? current, String? older) {
  // Only the older field says a version was taken off sale.
  if (older != null && _removedStates.contains(older)) return older;
  return current ?? older ?? '';
}

/// [phasedState] is the version's phased release state, when it has one.
ReleaseState versionState(String raw, {String? phasedState}) {
  final state = _versionStates[raw] ?? ReleaseState.unknown;
  if (state != ReleaseState.live) return state;
  return switch (phasedState) {
    'ACTIVE' => ReleaseState.rollingOut,
    'PAUSED' => ReleaseState.halted,
    _ => ReleaseState.live,
  };
}

/// The share of users a phased release has reached on [day], 1 to 7.
double? phasedFraction(int? day) {
  if (day == null || day < 1) return null;
  return day > _phasedShare.length ? 1.0 : _phasedShare[day - 1];
}

ReleaseState buildState(String? processingState, {required bool expired}) {
  if (expired) return ReleaseState.expired;
  return switch (processingState) {
    'PROCESSING' => ReleaseState.processing,
    'VALID' => ReleaseState.testing,
    'FAILED' || 'INVALID' => ReleaseState.rejected,
    _ => ReleaseState.unknown,
  };
}

String appStoreTrack(String? platform) => switch (platform) {
  null || 'IOS' => 'App Store',
  'MAC_OS' => 'App Store (macOS)',
  'TV_OS' => 'App Store (tvOS)',
  'VISION_OS' => 'App Store (visionOS)',
  _ => 'App Store ($platform)',
};

int _rank(StoreRelease release) {
  if (release.track == testFlightTrack) return 3;
  if (release.state == ReleaseState.live) return 0;
  if (release.state.inFlight || release.state.needsAttention) return 1;
  return 2;
}

/// Live first, then what is moving or stuck, then the rest, TestFlight last;
/// newest first within each.
List<StoreRelease> orderReleases(Iterable<StoreRelease> releases) {
  final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  return releases.toList()..sort((a, b) {
    final byRank = _rank(a).compareTo(_rank(b));
    if (byRank != 0) return byRank;
    return (b.date ?? epoch).compareTo(a.date ?? epoch);
  });
}
