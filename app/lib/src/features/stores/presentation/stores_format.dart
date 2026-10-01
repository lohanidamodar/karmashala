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

/// `Rolling out 20%`, `In review`.
String formatReleaseState(StoreRelease release) {
  final fraction = release.rolloutFraction;
  return fraction == null
      ? release.state.label
      : '${release.state.label} ${(fraction * 100).round()}%';
}

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
  StoreKind.appStore => 'Open in App Store Connect',
  StoreKind.googlePlay => 'Open the Play listing',
};
