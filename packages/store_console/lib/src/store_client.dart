import 'domain.dart';

/// Why a store call gave nothing.
enum StoreFailure {
  /// The credential was refused.
  auth,

  /// The credential is good and may not see this.
  permission,

  /// Something the user has not supplied yet: a vendor number, a bucket id.
  notConfigured,

  /// The store has no such number at all.
  notSupported,
  rateLimited,
  network,
  server,

  /// The store answered in a shape this does not read.
  shape,
}

class StoreException implements Exception {
  const StoreException(this.kind, this.message, {this.retryAfter});

  final StoreFailure kind;

  /// A sentence for the user, ending in the remedy when there is one. Never
  /// holds a secret.
  final String message;
  final Duration? retryAfter;

  @override
  String toString() => 'StoreException(${kind.name}): $message';
}

/// One store, read-only. Every method throws [StoreException] and nothing
/// else for a failure the user can be told about.
abstract interface class StoreClient {
  StoreKind get store;

  Future<List<StoreApp>> listApps();

  /// Newest and most relevant first: what is live, then what is in flight,
  /// then test tracks.
  Future<List<StoreRelease>> releases(StoreApp app);

  /// Newest first.
  Future<List<StoreReview>> reviews(StoreApp app);

  Future<RatingSummary> rating(StoreApp app);

  Future<VitalsSummary> vitals(StoreApp app);

  Future<DownloadSeries> downloads(StoreApp app);

  /// The app's icon from its public store page, about 128 px square; null
  /// when the app has no public page — unpublished, a draft, or not on the
  /// storefront asked. Read from public pages only, never through anything a
  /// release pipeline holds open (a Play edit).
  Future<StoreIconImage?> icon(StoreApp app);

  void close();
}
