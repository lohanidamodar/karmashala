import 'package:http/http.dart' as http;
import 'package:store_console/store_console.dart';

import 'play_account.dart';

/// Google Play, read-only.
class PlayStoreClient implements StoreClient {
  /// [httpClient] is the transport the token and every call go through; a
  /// test hands in a fake.
  PlayStoreClient(
    this.account, {
    http.Client? httpClient,
    DateTime Function()? now,
  }) : _http = httpClient ?? http.Client(),
       _now = now ?? DateTime.now;

  final PlayAccount account;
  final http.Client _http;
  // ignore: unused_field
  final DateTime Function() _now;

  @override
  StoreKind get store => StoreKind.googlePlay;

  @override
  Future<List<StoreApp>> listApps() => throw UnimplementedError();

  @override
  Future<List<StoreRelease>> releases(StoreApp app) =>
      throw UnimplementedError();

  @override
  Future<List<StoreReview>> reviews(StoreApp app) => throw UnimplementedError();

  @override
  Future<RatingSummary> rating(StoreApp app) => throw UnimplementedError();

  @override
  Future<VitalsSummary> vitals(StoreApp app) => throw UnimplementedError();

  @override
  Future<DownloadSeries> downloads(StoreApp app) => throw UnimplementedError();

  @override
  void close() => _http.close();
}
