import 'package:karmashala_ui/charts.dart';
import 'package:store_console/store_console.dart';

/// How old the data on screen is, in the roughest useful unit.
String formatDataAge(Duration age) {
  if (age.isNegative || age.inMinutes < 1) return 'just now';
  if (age.inHours < 1) return '${age.inMinutes} min ago';
  if (age.inDays < 1) return '${age.inHours} h ago';
  return '${age.inDays} d ago';
}

/// `4.6 ★ (1.2k)`, or `4.6 ★` when the store gave no count.
String formatRating(RatingSummary rating) {
  final average = '${rating.average.toStringAsFixed(1)} ★';
  final count = rating.count;
  return count == null ? average : '$average (${formatCompactCount(count)})';
}

/// A fraction of daily users as a percentage: `0.0123` is `1.23%`.
String formatRate(double fraction) => '${(fraction * 100).toStringAsFixed(2)}%';

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// The local day of [at] as people say it: `30 Sep`, with the year when it
/// is not [now]'s.
String formatShortDay(DateTime at, DateTime now) {
  final local = at.toLocal();
  final day = '${local.day} ${_months[local.month - 1]}';
  return local.year == now.toLocal().year ? day : '$day ${local.year}';
}

/// The local calendar day of [at], `2026-09-30`.
String formatDay(DateTime at) {
  final local = at.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '${local.year}-$month-$day';
}

/// A report's calendar day, kept as UTC midnight: converting it to local
/// time would show the day before anywhere west of UTC.
String formatReportDay(DateTime day) {
  final utc = day.toUtc();
  final month = utc.month.toString().padLeft(2, '0');
  final date = utc.day.toString().padLeft(2, '0');
  return '${utc.year}-$month-$date';
}

/// `1.4.0 (212)`, the version alone, or the build alone when the store names
/// only that.
String formatVersion(StoreRelease release) {
  final build = release.build;
  if (release.version.isEmpty) return build == null ? '—' : 'Build $build';
  return build == null ? release.version : '${release.version} ($build)';
}

/// `Rolling out 20%`, `In review`; a rollout whose share the store does not
/// say (Google Play's read-only API) is a `Staged rollout`.
String formatReleaseState(StoreRelease release) {
  final fraction = release.rolloutFraction;
  if (fraction != null) {
    return '${release.state.label} ${(fraction * 100).round()}%';
  }
  if (release.state == ReleaseState.rollingOut &&
      !release.track.startsWith('App Store')) {
    return 'Staged rollout';
  }
  return release.state.label;
}

/// A track as the store's console names it: Play's `beta` is Open testing.
String formatTrack(String track) => switch (track) {
  'production' => 'Production',
  'beta' => 'Open testing',
  'alpha' => 'Closed testing',
  'internal' => 'Internal testing',
  _ => track,
};

/// Whether [track] is where the public gets the app, not a test track.
bool isPublicTrack(String track) =>
    track == 'production' || track.startsWith('App Store');

/// A rating's change as a signed figure: `+0.1`, `−0.2`, `±0.0`.
String formatRatingChange(double change) {
  final rounded = (change * 10).round() / 10;
  if (rounded == 0) return '±0.0';
  return rounded > 0
      ? '+${rounded.toStringAsFixed(1)}'
      : '−${(-rounded).toStringAsFixed(1)}';
}

/// One store's way out of Karmashala for [app]: a label and its address.
typedef StoreLink = ({String label, String url});

/// Where [app] can be looked at outside Karmashala, console first.
List<StoreLink> storeLinks(StoreApp app) => [
  (label: storePageLabel(app.store), url: storePageUrl(app)),
  if (storeConsoleUrl(app) case final console?)
    (label: 'Play Console', url: console),
];

String formatStars(int rating) {
  final filled = rating.clamp(0, 5);
  return '${'★' * filled}${'☆' * (5 - filled)}';
}

/// The page for [app] outside Karmashala. Play Console has no stable per-app
/// address without the developer id, so Play opens the public listing.
String storePageUrl(StoreApp app) => switch (app.store) {
  StoreKind.appStore => 'https://appstoreconnect.apple.com/apps/${app.id}',
  StoreKind.googlePlay =>
    'https://play.google.com/store/apps/details?id=${app.id}',
};

/// Play Console for a Google Play app, or null for the App Store, whose
/// [storePageUrl] is already its console. Not the app's own page: a console
/// deep link needs the developer account and Play's internal app id, and no
/// API this reads gives the app id — the old `apps/publish/?package=` link
/// drops the package (checked 2026-10-01). The app list is one click away.
String? storeConsoleUrl(StoreApp app) => switch (app.store) {
  StoreKind.appStore => null,
  StoreKind.googlePlay => 'https://play.google.com/console/u/0/developers',
};

String storePageLabel(StoreKind store) => switch (store) {
  StoreKind.appStore => 'App Store Connect',
  StoreKind.googlePlay => 'Play listing',
};

/// The short name a store goes by beside a version: `App Store`, `Play`.
String storeShortLabel(StoreKind store) => switch (store) {
  StoreKind.appStore => 'App Store',
  StoreKind.googlePlay => 'Play',
};

/// A page where a store credential is made or found, for Settings → Stores.
typedef StoreSetupLink = ({String label, String url});

/// App Store Connect's pages for the key and the vendor number. Both are
/// fixed addresses: the team is the signed-in one.
const List<StoreSetupLink> appleSetupLinks = [
  (
    label: 'API keys',
    url: 'https://appstoreconnect.apple.com/access/integrations/api',
  ),
  (
    label: 'Users and Access',
    url: 'https://appstoreconnect.apple.com/access/users',
  ),
  (
    label: 'Payments and Financial Reports',
    url: 'https://appstoreconnect.apple.com/itc/payments_and_financial_reports',
  ),
];

/// Play Console, and the Google Cloud pages for [clientEmail]'s project —
/// read off the service account's address (`…@PROJECT.iam.gserviceaccount
/// .com`) — and for [bucket] when one is set. Play Console has no stable
/// page address without the developer id, so it opens the console itself.
List<StoreSetupLink> playSetupLinks({String? clientEmail, String? bucket}) {
  final project = cloudProjectOf(clientEmail);
  final inProject = project == null
      ? ''
      : '?project=${Uri.encodeQueryComponent(project)}';
  final bucketName = reportsBucketName(bucket);
  return [
    (
      label: 'Play Console',
      url: 'https://play.google.com/console/u/0/developers',
    ),
    (
      label: 'Play Developer API',
      url:
          'https://console.cloud.google.com/apis/library/'
          'androidpublisher.googleapis.com$inProject',
    ),
    (
      label: 'Play Reporting API',
      url:
          'https://console.cloud.google.com/apis/library/'
          'playdeveloperreporting.googleapis.com$inProject',
    ),
    (
      label: 'Service accounts',
      url:
          'https://console.cloud.google.com/iam-admin/serviceaccounts$inProject',
    ),
    if (bucketName != null)
      (
        label: 'Reports bucket',
        url:
            'https://console.cloud.google.com/storage/browser/'
            '${Uri.encodeComponent(bucketName)}',
      ),
  ];
}

/// The Google Cloud project a service account belongs to, from its address,
/// or null for an address that is not a service account's.
String? cloudProjectOf(String? clientEmail) {
  final match = RegExp(
    r'^[^@]+@([a-z][a-z0-9-]{4,28}[a-z0-9])\.iam\.gserviceaccount\.com$',
  ).firstMatch(clientEmail?.trim() ?? '');
  return match?.group(1);
}

/// The bucket's name from what was typed: `pubsite_prod_rev_…`, or the
/// `gs://pubsite_prod_rev_…/stats/…` URI Play Console copies. Null when empty.
String? reportsBucketName(String? bucket) {
  var name = bucket?.trim() ?? '';
  if (name.startsWith('gs://')) name = name.substring(5);
  name = name.split('/').first;
  return name.isEmpty ? null : name;
}
