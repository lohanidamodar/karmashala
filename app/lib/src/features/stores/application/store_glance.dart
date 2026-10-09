import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show StoreAppChanges, StoreChangeKind;
import 'package:riverpod/riverpod.dart';

import 'store_summary.dart';
import 'stores_controller.dart';

/// What the dashboard's Stores glance shows: a small read-only summary of the
/// Stores tab.
class StoresGlanceData {
  const StoresGlanceData({
    required this.attention,
    this.firstAttention,
    this.newestRelease,
    this.ratingApp,
    this.ratingTrend = const [],
    this.rating,
  });

  /// Apps (one per store) that need the owner.
  final int attention;

  /// The first of them as a person names it: `One (iOS)`.
  final String? firstAttention;

  /// The newest release state change any read found: `1.34.6 Live`, when.
  final ({String text, DateTime at, String app})? newestRelease;

  /// The app the sparkline follows: the one with the most ratings.
  final String? ratingApp;

  /// Its average a day over the last month, oldest first, days unread left
  /// out.
  final List<double> ratingTrend;
  final double? rating;
}

/// [change]'s text said short: `1.34.4 Approved → Ready for sale` is
/// `1.34.4 Ready for sale`, `New 1.35.0: Waiting for review` is `1.35.0
/// Waiting for review`.
String shortReleaseChange(String change) {
  var text = change.startsWith('New ') ? change.substring(4) : change;
  final arrow = text.lastIndexOf(' → ');
  if (arrow >= 0) {
    final space = text.indexOf(' ');
    final name = space < 0 ? text : text.substring(0, space);
    return '$name ${text.substring(arrow + 3)}';
  }
  text = text.replaceFirst(': ', ' ');
  return text;
}

/// The newest release change among each app's latest changes, or null.
({String text, DateTime at, String app})? newestReleaseChange(
  Iterable<StoreAppChanges> changes,
) {
  ({String text, DateTime at, String app})? newest;
  for (final held in changes) {
    for (final change in held.changes) {
      if (change.kind != StoreChangeKind.release) continue;
      if (newest == null || held.at.isAfter(newest.at)) {
        newest = (
          text: shortReleaseChange(change.text),
          at: held.at,
          app: held.title,
        );
      }
      break;
    }
  }
  return newest;
}

/// The Stores glance's data; null until the stores have been asked, or with
/// no store connected.
final storesGlanceProvider = Provider<StoresGlanceData?>((ref) {
  final state = ref.watch(storesProvider).value;
  if (state == null || state.connected.isEmpty) return null;
  final rows = storeSummaryRows(state.groups);
  final attention = rows.where((row) => row.needsAttention).toList();
  StoreSummaryRow? rated;
  for (final row in rows) {
    final count = row.rating?.count ?? -1;
    if (row.rating != null &&
        (rated == null || count > (rated.rating?.count ?? -1))) {
      rated = row;
    }
  }
  return StoresGlanceData(
    attention: attention.length,
    firstAttention: attention.isEmpty
        ? null
        : '${attention.first.app.name} (${attention.first.platform})',
    newestRelease: newestReleaseChange(state.view.changes),
    ratingApp: rated == null ? null : '${rated.app.name} (${rated.platform})',
    ratingTrend: rated?.ratingTrend ?? const [],
    rating: rated?.rating?.average,
  );
});
