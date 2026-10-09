import 'dart:convert';
import 'dart:io';

import 'package:store_console/store_console.dart';

/// Names the file a probe's stores are read from, instead of Apple and
/// Google: `{"apps": [StoreAppSnapshot JSON, ...]}`, read again on every
/// call, so editing it between refreshes is a change at the store.
const String kProbeStoreFixtureVariable = 'KARMASHALA_PROBE_STORE_FIXTURE';

/// The fixture [environment] names, or null: honoured only in a probe
/// (`KARMASHALA_PROBE`), so no other server can be pointed off the stores.
File? probeStoreFixture(Map<String, String> environment) {
  final probe = (environment['KARMASHALA_PROBE'] ?? '').trim().toLowerCase();
  if (!const {'1', 'true', 'yes', 'on'}.contains(probe)) return null;
  final path = environment[kProbeStoreFixtureVariable]?.trim() ?? '';
  return path.isEmpty ? null : File(path);
}

/// One store answered from a probe's fixture file. Never reaches a network.
class FixtureStoreClient implements StoreClient, StoreErrorIssueSource {
  FixtureStoreClient(this.store, this.file);

  @override
  final StoreKind store;
  final File file;

  List<StoreAppSnapshot> _read() {
    try {
      final decoded = (jsonDecode(file.readAsStringSync()) as Map)
          .cast<String, Object?>();
      return [
        for (final app in (decoded['apps'] as List?) ?? const [])
          StoreAppSnapshot.fromJson((app as Map).cast<String, Object?>()),
      ].where((snapshot) => snapshot.app.store == store).toList();
    } on Object catch (error) {
      throw StoreException(
        StoreFailure.shape,
        'The probe\'s store fixture was not read (${error.runtimeType}).',
      );
    }
  }

  StoreAppSnapshot _of(StoreApp app) => _read().firstWhere(
    (snapshot) => snapshot.app == app,
    orElse: () => throw const StoreException(
      StoreFailure.shape,
      'The probe\'s store fixture has no such app.',
    ),
  );

  static T _value<T>(Reading<T>? reading) => switch (reading) {
    ReadingValue(:final value) => value,
    ReadingMissing(:final kind, :final message) => throw StoreException(
      kind,
      message,
    ),
    null => throw const StoreException(
      StoreFailure.notSupported,
      'Not in the probe\'s fixture.',
    ),
  };

  @override
  Future<List<StoreApp>> listApps() async => [
    for (final snapshot in _read()) snapshot.app,
  ];

  @override
  Future<List<StoreRelease>> releases(StoreApp app) async =>
      _value(_of(app).releases);

  @override
  Future<List<StoreReview>> reviews(StoreApp app) async =>
      _value(_of(app).reviews);

  @override
  Future<RatingSummary> rating(StoreApp app) async => _value(_of(app).rating);

  @override
  Future<VitalsSummary> vitals(StoreApp app) async => _value(_of(app).vitals);

  @override
  Future<DownloadSeries> downloads(StoreApp app) async =>
      _value(_of(app).downloads);

  @override
  Future<List<StoreErrorIssue>> errorIssues(StoreApp app) async =>
      _value(_of(app).errorIssues);

  @override
  Future<StoreIconImage?> icon(StoreApp app) async => null;

  @override
  void close() {}
}
