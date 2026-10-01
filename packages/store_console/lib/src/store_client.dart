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

  /// The app's icon, about 128 px square: from its public store page, else a
  /// read-only API where the store has one; null when neither has it. Never
  /// read through anything a release pipeline holds open (a Play edit).
  Future<StoreIconImage?> icon(StoreApp app);

  void close();
}

/// A store that groups its crash and ANR reports into issues. Apart from
/// [StoreClient] so a store without them, and every fake, need not say so.
abstract interface class StoreErrorIssueSource {
  /// The most reported crash and ANR clusters over the last weeks, most
  /// reported first; a few carry a sample stack trace.
  Future<List<StoreErrorIssue>> errorIssues(StoreApp app);
}

/// A store whose own reports count every install or download an app has had.
abstract interface class StoreInstallTotalSource {
  /// The all-time count from the store's reports; throws [StoreException]
  /// when they cannot say, never answers a guess.
  Future<InstallTotal> allTimeInstalls(StoreApp app);
}

/// A store whose public page says more than the icon, read in the same
/// request. Null when the app has no public page.
abstract interface class StoreListingSource {
  Future<StoreListing?> listing(StoreApp app);
}
